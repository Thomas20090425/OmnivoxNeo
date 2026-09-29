import Combine
import EventKit
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// How long before an event the student wants to hear about it.
enum CalendarReminderLead: String, CaseIterable, Identifiable, Sendable {
    case none
    case atTime
    case oneHour
    case oneDay
    case twoDays

    var id: String { rawValue }

    /// Seconds before the start, as EventKit wants it (negative = before).
    ///
    /// All-day entries start at midnight, so a plain "one day before" would
    /// fire at midnight the night before — technically correct and useless.
    /// Those are nudged to 9am instead.
    func relativeOffset(isAllDay: Bool) -> TimeInterval? {
        switch self {
        case .none:
            nil
        case .atTime:
            isAllDay ? 9 * 3600 : 0
        case .oneHour:
            isAllDay ? -15 * 3600 : -3600
        case .oneDay:
            isAllDay ? -15 * 3600 : -24 * 3600
        case .twoDays:
            isAllDay ? -39 * 3600 : -48 * 3600
        }
    }
}

/// What the student asked the app to mirror into their phone's calendar.
///
/// Scoped to the profile: two students sharing a device subscribe separately,
/// and one signing out must not keep writing into the other's calendar.
@MainActor
final class CalendarSubscription: ObservableObject {
    private let defaults: UserDefaults
    private let profileID: UUID

    private(set) var categories: Set<PortalCalendarEvent.Category>
    private(set) var reminderLead: CalendarReminderLead
    private(set) var lastSyncedAt: Date?

    var isSubscribed: Bool { !categories.isEmpty }

    init(profileID: UUID, defaults: UserDefaults = .standard) {
        self.profileID = profileID
        self.defaults = defaults

        let stored = defaults.stringArray(forKey: Self.key("categories", profileID)) ?? []
        categories = Set(stored.compactMap(PortalCalendarEvent.Category.init(rawValue:)))
        reminderLead = CalendarReminderLead(
            rawValue: defaults.string(forKey: Self.key("reminder", profileID)) ?? ""
        ) ?? .oneDay
        lastSyncedAt = defaults.object(forKey: Self.key("last-sync", profileID)) as? Date
    }

    func contains(_ category: PortalCalendarEvent.Category) -> Bool {
        categories.contains(category)
    }

    func setCategory(_ category: PortalCalendarEvent.Category, subscribed: Bool) {
        objectWillChange.send()
        if subscribed {
            categories.insert(category)
        } else {
            categories.remove(category)
        }
        defaults.set(
            categories.map(\.rawValue).sorted(),
            forKey: Self.key("categories", profileID)
        )
    }

    func setReminderLead(_ lead: CalendarReminderLead) {
        objectWillChange.send()
        reminderLead = lead
        defaults.set(lead.rawValue, forKey: Self.key("reminder", profileID))
    }

    func recordSync(at date: Date) {
        objectWillChange.send()
        lastSyncedAt = date
        defaults.set(date, forKey: Self.key("last-sync", profileID))
    }

    /// Dropped when the account is removed, alongside everything else it owns.
    func clear() {
        objectWillChange.send()
        categories = []
        lastSyncedAt = nil
        for name in ["categories", "reminder", "last-sync"] {
            defaults.removeObject(forKey: Self.key(name, profileID))
        }
    }

    private static func key(_ name: String, _ profileID: UUID) -> String {
        "calendar-sync.\(name).\(profileID.uuidString)"
    }
}

/// Mirrors agenda events into the phone's own Calendar app.
///
/// The app writes into a calendar it creates and owns, never into the student's
/// personal one, so "unsubscribe" can mean "delete everything we put there"
/// without any risk of taking something of theirs with it.
///
/// Every write is an upsert keyed by `calendarSyncKey`: re-running a sync after
/// the portal changes a room or a time updates the entry the student already
/// has, and anything the portal has stopped listing is removed. That is what
/// makes it safe to run automatically after every sign-in.
@MainActor
enum CalendarSyncService {
    /// Carries an already-localized message rather than resolving one on
    /// demand: `errorDescription` is read from wherever the error lands, while
    /// the app's chosen language is main-actor state. Resolving at the throw
    /// site — which is always on the main actor — keeps both true.
    struct SyncError: LocalizedError {
        let message: String

        var errorDescription: String? { message }

        @MainActor
        static var accessDenied: SyncError {
            SyncError(message: Loc.text("Omnivox Neo needs permission to add events to your calendar. You can grant it in Settings."))
        }

        @MainActor
        static var noWritableCalendar: SyncError {
            SyncError(message: Loc.text("No calendar on this device can be written to."))
        }

        static func underlying(_ message: String) -> SyncError {
            SyncError(message: message)
        }
    }

    struct Outcome {
        var added = 0
        var updated = 0
        var removed = 0

        var isEmpty: Bool { added == 0 && updated == 0 && removed == 0 }
    }

    /// How far ahead to mirror. A year covers the academic calendar's own
    /// horizon; beyond that the portal has nothing to say anyway.
    private static let horizon: TimeInterval = 400 * 24 * 3600
    /// A little history, so this morning's deadline does not vanish at noon.
    private static let lookBehind: TimeInterval = 7 * 24 * 3600

    static func requestAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// What the app is currently allowed to do with the calendar.
    ///
    /// Modelled explicitly rather than as a bool because the interesting case
    /// is in the middle: iOS 17 split calendar access into write-only and full,
    /// and write-only is not enough here. Keeping a mirror correct means
    /// reading back what was written so it can be updated and pruned — with
    /// write-only, every sync would pile up duplicates it could not see.
    enum Access: Sendable {
        case notRequested
        case writeOnly
        case full
        case refused
    }

    /// Exposed as a plain enum so callers need no EventKit import — the app
    /// model has no other reason to know that framework exists.
    static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .full
        case .writeOnly: .writeOnly
        case .denied, .restricted: .refused
        case .notDetermined: .notRequested
        @unknown default: .notRequested
        }
    }

    static var isAuthorized: Bool { access == .full }

    @discardableResult
    static func sync(
        events: [PortalCalendarEvent],
        institution: Institution,
        profileID: UUID,
        subscription: CalendarSubscription
    ) async throws -> Outcome {
        guard subscription.isSubscribed else {
            try removeEverything(profileID: profileID)
            return Outcome()
        }

        guard access == .full else {
            throw SyncError.accessDenied
        }

        let store = EKEventStore()
        let calendar = try calendar(in: store, institution: institution, profileID: profileID)

        let now = Date()
        let window = (now - lookBehind)...(now + horizon)
        // Last write wins on a duplicate key, which is also what the portal
        // means when it lists the same item twice.
        let desired = Dictionary(
            events
                .filter { subscription.contains($0.category) }
                .filter { window.contains($0.start) }
                .map { ($0.calendarSyncKey, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        var mapping = storedMapping(profileID: profileID)
        var outcome = Outcome()

        for (key, event) in desired {
            let existing = mapping[key].flatMap { store.event(withIdentifier: $0) }

            if let existing, existing.calendar?.calendarIdentifier == calendar.calendarIdentifier {
                if apply(event, to: existing, institution: institution, lead: subscription.reminderLead) {
                    try store.save(existing, span: .thisEvent, commit: false)
                    outcome.updated += 1
                }
            } else {
                let created = EKEvent(eventStore: store)
                created.calendar = calendar
                _ = apply(event, to: created, institution: institution, lead: subscription.reminderLead)
                try store.save(created, span: .thisEvent, commit: false)
                mapping[key] = created.eventIdentifier
                outcome.added += 1
            }
        }

        // Anything the portal no longer lists — a cancelled event, or a
        // category the student just unsubscribed from.
        for (key, identifier) in mapping where desired[key] == nil {
            if let stale = store.event(withIdentifier: identifier),
               stale.calendar?.calendarIdentifier == calendar.calendarIdentifier {
                try store.remove(stale, span: .thisEvent, commit: false)
                outcome.removed += 1
            }
            mapping[key] = nil
        }

        try store.commit()
        persist(mapping: mapping, profileID: profileID)
        subscription.recordSync(at: now)
        return outcome
    }

    /// Deletes the app's calendar and forgets every event it wrote.
    static func removeEverything(profileID: UUID) throws {
        defer {
            UserDefaults.standard.removeObject(forKey: mappingKey(profileID))
            UserDefaults.standard.removeObject(forKey: calendarKey(profileID))
        }

        guard access == .full else { return }
        let store = EKEventStore()
        guard
            let identifier = UserDefaults.standard.string(forKey: calendarKey(profileID)),
            let calendar = store.calendar(withIdentifier: identifier)
        else {
            return
        }
        try store.removeCalendar(calendar, commit: true)
    }

    // MARK: - Event contents

    /// Writes the portal's version of an event onto an EventKit one, and says
    /// whether anything actually changed — so an unchanged sync commits nothing
    /// and leaves the student's calendar alone.
    private static func apply(
        _ event: PortalCalendarEvent,
        to target: EKEvent,
        institution: Institution,
        lead: CalendarReminderLead
    ) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = institution.timeZone

        let title = event.title
        let location = event.location
        let notes = notes(for: event, institution: institution)
        let url = event.links
            .first { !$0.isPortalInternal(domainSuffix: institution.conventions.portalDomainSuffix) }?
            .url

        let start: Date
        let end: Date
        if event.isAllDay {
            start = calendar.startOfDay(for: event.start)
            // Our end is exclusive (the start of the following day); EventKit
            // wants the last day itself.
            let lastMoment = (event.end ?? start.addingTimeInterval(24 * 3600))
                .addingTimeInterval(-1)
            end = max(start, calendar.startOfDay(for: lastMoment))
        } else {
            start = event.start
            end = event.end ?? event.start.addingTimeInterval(3600)
        }

        let offset = lead.relativeOffset(isAllDay: event.isAllDay)
        let existingOffset = target.alarms?.first?.relativeOffset

        // Compared leniently on purpose. EventKit hands back "" where nil went
        // in and rounds dates to the second, so a strict comparison reported
        // every event as changed on every sync — rewriting the student's whole
        // calendar, and bumping its modification date, to change nothing.
        let unchanged = target.title == title
            && emptyAsNil(target.location) == emptyAsNil(location)
            && emptyAsNil(target.notes) == emptyAsNil(notes)
            && target.url == url
            && target.isAllDay == event.isAllDay
            && sameInstant(target.startDate, start)
            && sameInstant(target.endDate, end)
            && sameOffset(existingOffset, offset)
        if unchanged { return false }

        target.title = title
        target.location = location
        target.notes = notes
        target.url = url
        target.isAllDay = event.isAllDay
        target.startDate = start
        target.endDate = end
        target.timeZone = event.isAllDay ? nil : institution.timeZone

        target.alarms?.forEach(target.removeAlarm)
        if let offset {
            target.addAlarm(EKAlarm(relativeOffset: offset))
        }

        return true
    }

    private static func emptyAsNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Within a second is the same moment here: the portal works in minutes.
    private static func sameInstant(_ left: Date?, _ right: Date?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return abs(left.timeIntervalSince(right)) < 1
    }

    private static func sameOffset(_ left: TimeInterval?, _ right: TimeInterval?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return abs(left - right) < 1
    }

    private static func notes(
        for event: PortalCalendarEvent,
        institution: Institution
    ) -> String {
        var lines: [String] = []

        var heading = event.category.plainLabel(institution.conventions)
        if let subtitle = event.subtitle, subtitle != heading {
            heading += " · \(subtitle)"
        }
        lines.append(heading)

        if let detail = event.detail, !detail.isEmpty {
            lines.append("")
            lines.append(detail)
        }

        // Portal links are left in as plain text rather than as the event's
        // URL: tapping one from the Calendar app would land on a login wall.
        if !event.links.isEmpty {
            lines.append("")
            for link in event.links {
                lines.append("\(link.displayTitle): \(link.url.absoluteString)")
            }
        }

        lines.append("")
        lines.append(Loc.text("Added by Omnivox Neo · %@", institution.displayName))
        return lines.joined(separator: "\n")
    }

    // MARK: - The app's own calendar

    private static func calendar(
        in store: EKEventStore,
        institution: Institution,
        profileID: UUID
    ) throws -> EKCalendar {
        if
            let identifier = UserDefaults.standard.string(forKey: calendarKey(profileID)),
            let existing = store.calendar(withIdentifier: identifier)
        {
            return existing
        }

        guard let source = writableSource(in: store) else {
            throw SyncError.noWritableCalendar
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Loc.text("%@ · Omnivox Neo", institution.displayName)
        calendar.source = source
        calendar.cgColor = calendarColor

        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw SyncError.underlying(error.localizedDescription)
        }

        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: calendarKey(profileID))
        return calendar
    }

    /// Prefers whatever source the student's own default calendar lives in, so
    /// a school calendar syncs to their other devices the way their personal
    /// ones do. Falls back to the on-device store.
    private static func writableSource(in store: EKEventStore) -> EKSource? {
        if let source = store.defaultCalendarForNewEvents?.source,
           source.sourceType != .birthdays,
           source.sourceType != .subscribed {
            return source
        }
        if let local = store.sources.first(where: { $0.sourceType == .local }) {
            return local
        }
        return store.sources.first {
            $0.sourceType != .birthdays && $0.sourceType != .subscribed
        }
    }

    // MARK: - Key mapping

    private static func storedMapping(profileID: UUID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: mappingKey(profileID)) as? [String: String] ?? [:]
    }

    private static func persist(mapping: [String: String], profileID: UUID) {
        UserDefaults.standard.set(mapping, forKey: mappingKey(profileID))
    }

    private static func mappingKey(_ profileID: UUID) -> String {
        "calendar-sync.events.\(profileID.uuidString)"
    }

    private static func calendarKey(_ profileID: UUID) -> String {
        "calendar-sync.calendar.\(profileID.uuidString)"
    }

    /// The school calendar wears the student's accent, so it is recognisable
    /// among their own calendars at a glance.
    private static var calendarColor: CGColor {
        let accent = Personalization.shared.accent.color
        #if canImport(UIKit)
        return UIColor(accent).cgColor
        #elseif canImport(AppKit)
        return NSColor(accent).cgColor
        #else
        return CGColor(red: 0.04, green: 0.36, blue: 0.72, alpha: 1)
        #endif
    }
}
