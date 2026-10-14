import EventKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Subscribe the phone's Calendar app to the agenda.
///
/// Per category, because the categories are genuinely different commitments:
/// a student may want every Léa deadline as a reminder and not a single bake
/// sale. Once subscribed, every sign-in re-syncs silently — the promise here is
/// that the calendar stays right without being tended.
///
/// Permission is its own visible step rather than something the first toggle
/// does on the way past. Hiding it there meant that when the request did not
/// come back, the toggle simply refused to move and said nothing — the screen
/// looked broken, which is the worst way to ask someone for access.
struct CalendarSyncSettingsView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var model: AppModel
    @ObservedObject private var subscription: CalendarSubscription

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var access = CalendarSyncService.access
    @State private var isRequestingAccess = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var result: CalendarSyncService.Outcome?

    init(model: AppModel) {
        self.model = model
        _subscription = ObservedObject(wrappedValue: model.calendarSubscription)
    }

    private var conventions: PortalConventions { model.institution.conventions }

    private var hasAccess: Bool { access == .full }

    var body: some View {
        NavigationStack {
            List {
                accessSection
                categoriesSection

                if hasAccess {
                    reminderSection
                    syncSection
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .scrollContentBackground(.hidden)
            .background(NeoBackground())
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // The student may have changed this in Settings since the sheet
                // was last opened.
                access = CalendarSyncService.access
            }
        }
    }

    // MARK: - Access

    @ViewBuilder
    private var accessSection: some View {
        if !hasAccess {
            Section {
                switch access {
                case .notRequested:
                    Button {
                        Task { await requestAccess() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "calendar.badge.plus")
                            Text("Allow Calendar Access")
                            Spacer()
                            if isRequestingAccess {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isRequestingAccess)

                case .writeOnly, .refused, .full:
                    Button {
                        openSystemSettings()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "gearshape")
                            Text("Open Settings")
                        }
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text(accessExplanation)
            }
        }
    }

    private var accessExplanation: LocalizedStringKey {
        switch access {
        case .notRequested:
            "Omnivox Neo keeps its own calendar and writes your agenda into it."
        case .writeOnly:
            // Write-only genuinely cannot work here, and saying so beats
            // letting the student wonder why nothing updates.
            "Omnivox Neo has permission to add events but not to read them back, so it cannot keep them up to date. Choose Full Access in Settings."
        case .refused, .full:
            // `.full` never reaches here — the whole section is hidden once
            // access is granted — but it shares the case rather than returning
            // an empty string, which would land in the string catalog as a
            // blank key for a translator to puzzle over.
            "Calendar access is turned off for Omnivox Neo."
        }
    }

    // MARK: - Sections

    private var categoriesSection: some View {
        Section {
            ForEach(PortalCalendarEvent.Category.agendaCategories, id: \.self) { category in
                Toggle(isOn: binding(for: category)) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(category.tint)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 2) {
                            category.label(conventions)
                                .foregroundStyle(.primary)

                            Text("\(count(of: category)) upcoming")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(Neo.accent)
                .disabled(isWorking || !hasAccess)
            }
        } header: {
            Text("Add to Calendar")
        } footer: {
            Text("Chosen categories appear in a calendar of their own, kept separate from yours. Removing the subscription removes that calendar and everything in it.")
        }
    }

    private var reminderSection: some View {
        Section {
            Picker("Remind Me", selection: reminderBinding) {
                ForEach(CalendarReminderLead.allCases) { lead in
                    Text(lead.title).tag(lead)
                }
            }
            .disabled(isWorking || !subscription.isSubscribed)
        } footer: {
            Text("All-day events remind you at 9:00 AM rather than at midnight.")
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task { await syncNow() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync Now")
                    Spacer()
                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isWorking || !subscription.isSubscribed)

            if subscription.isSubscribed {
                Button(role: .destructive) {
                    Task { await unsubscribe() }
                } label: {
                    Text("Remove Subscription")
                }
                .disabled(isWorking)
            }
        } header: {
            Text("Sync")
        } footer: {
            statusFooter
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
        } else if let result {
            Text(summary(of: result))
        } else if let last = subscription.lastSyncedAt {
            Text("Last synced \(AgendaFormat.fullDate(last, timeZone: model.institution.timeZone)) at \(AgendaFormat.time(last, timeZone: model.institution.timeZone)).")
        } else if subscription.isSubscribed {
            Text("Your calendar updates automatically every time you sign in.")
        } else {
            Text("Turn on a category above to start.")
        }
    }

    // MARK: - Bindings

    private func binding(for category: PortalCalendarEvent.Category) -> Binding<Bool> {
        Binding(
            get: { subscription.contains(category) },
            set: { isOn in
                // Flipped immediately, so the switch answers the tap even if
                // the sync behind it takes a moment or fails.
                subscription.setCategory(category, subscribed: isOn)
                Task { await categoriesChanged() }
            }
        )
    }

    private var reminderBinding: Binding<CalendarReminderLead> {
        Binding(
            get: { subscription.reminderLead },
            set: { lead in
                subscription.setReminderLead(lead)
                Task { await syncNow() }
            }
        )
    }

    // MARK: - Actions

    private func requestAccess() async {
        isRequestingAccess = true
        defer {
            isRequestingAccess = false
            access = CalendarSyncService.access
        }
        _ = await CalendarSyncService.requestAccess()
    }

    private func categoriesChanged() async {
        errorMessage = nil
        result = nil

        if subscription.isSubscribed {
            await syncNow()
        } else {
            await unsubscribe()
        }
    }

    private func syncNow() async {
        guard subscription.isSubscribed, hasAccess else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        guard let profileID = model.activeProfileID else { return }

        do {
            result = try await CalendarSyncService.sync(
                events: model.calendarEvents,
                institution: model.institution,
                profileID: profileID,
                subscription: subscription
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unsubscribe() async {
        guard let profileID = model.activeProfileID else { return }
        isWorking = true
        defer { isWorking = false }

        // A full reset, including the "last synced" stamp: leaving it behind
        // left the screen claiming a sync that no longer has a calendar.
        subscription.clear()

        do {
            try CalendarSyncService.removeEverything(profileID: profileID)
            result = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func count(of category: PortalCalendarEvent.Category) -> Int {
        let now = Date()
        return model.calendarEvents.filter {
            $0.category == category && !$0.hasPassed(by: now)
        }.count
    }

    private func summary(of outcome: CalendarSyncService.Outcome) -> String {
        guard !outcome.isEmpty else {
            return Loc.text("Already up to date.")
        }
        var parts: [String] = []
        if outcome.added > 0 { parts.append(Loc.text("%d added", outcome.added)) }
        if outcome.updated > 0 { parts.append(Loc.text("%d updated", outcome.updated)) }
        if outcome.removed > 0 { parts.append(Loc.text("%d removed", outcome.removed)) }
        return parts.joined(separator: " · ")
    }

    private func openSystemSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
        #endif
    }
}

extension CalendarReminderLead {
    var title: LocalizedStringKey {
        switch self {
        case .none: "No reminder"
        case .atTime: "At time of event"
        case .oneHour: "1 hour before"
        case .oneDay: "1 day before"
        case .twoDays: "2 days before"
        }
    }
}
