import SwiftUI

/// The public roadmap, and the way on to it.
///
/// Two halves of one idea. The top of the screen is how somebody reports a
/// problem; everything below it is what happened to everybody else's reports.
/// Putting them together is the point — the usual experience of sending
/// feedback to an app is that it disappears, and the cure for that is not a
/// better confirmation message, it is being able to see the list.
struct CommunityFeedbackView: View {
    @StateObject private var service = CommunityFeedbackService()
    @State private var filter: CommunityIssueFilter = .all
    @State private var isSubmitting = false
    @State private var submittedIssueNumber: Int?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            filterControl
            roadmap
        }
        .background(NeoBackground())
        .navigationTitle("Feedback and Roadmap")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        openURL(CommunityFeedbackService.repositoryIssuesURL)
                    } label: {
                        Label("Open the Roadmap on GitHub", systemImage: "safari")
                    }
                    Button { service.refresh() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isSubmitting) {
            FeedbackSubmissionView { outcome in
                isSubmitting = false
                if case .closed(let issue) = outcome {
                    submittedIssueNumber = issue
                    // Whether or not anything was sent, the list is the only
                    // honest confirmation, so it is brought up to date rather
                    // than a thank-you being shown on faith.
                    service.refresh()
                }
            }
        }
        .task { service.loadIfNeeded() }
        .alert(
            "Thank You",
            isPresented: Binding(
                get: { submittedIssueNumber != nil },
                set: { if !$0 { submittedIssueNumber = nil } }
            )
        ) {
            Button("OK") { submittedIssueNumber = nil }
        } message: {
            if let number = submittedIssueNumber {
                // The number goes in as a string for the same reason: it is an
                // identifier, and a grouping separator in one would be wrong
                // in every language.
                Text("Your report is on the roadmap as #\(String(number)). It will appear in the list below, under Under Review.")
            }
        }
    }

    // MARK: - Filter

    private var filterControl: some View {
        Picker("Show", selection: $filter.animation(.easeInOut(duration: 0.18))) {
            ForEach(CommunityIssueFilter.allCases) { option in
                // Wrapped, not passed straight in: `Text(aString)` picks the
                // verbatim initializer and ships the English through.
                Text(LocalizedStringKey(option.title)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - The list

    @ViewBuilder
    private var roadmap: some View {
        let groups = service.groups(matching: filter)

        List {
            Section {
                submitCard
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let warning = service.staleWarning {
                Section {
                    SessionErrorBanner(
                        message: Loc.text(
                            "Showing the last copy — %@", warning.title.lowercased()
                        )
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            switch service.state {
            case .loading where service.issues.isEmpty:
                loadingPlaceholder

            case .failed(let error):
                failure(error)

            default:
                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.group) { entry in
                        Section {
                            ForEach(entry.issues) { issue in
                                NavigationLink {
                                    CommunityIssueDetailView(issue: issue)
                                } label: {
                                    CommunityIssueRow(issue: issue)
                                }
                            }
                        } header: {
                            Text(LocalizedStringKey(entry.group.title))
                        } footer: {
                            Text(LocalizedStringKey(entry.group.explanation))
                        }
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                listFooter
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await service.refreshAndWait() }
    }

    private var submitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Found a problem? Want something added?")
                    .font(.headline)
                Text("It goes to one person — the student who writes this app — and it lands on the list below, in public, where you can watch what happens to it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                isSubmitting = true
            } label: {
                Label("Report a Bug or Request a Feature", systemImage: "square.and.pencil")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }

    // MARK: - The states that are not a list

    private var loadingPlaceholder: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the roadmap…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 28)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func failure(_ error: CommunityFeedbackError) -> some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: error.systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(error.title)
                    .font(.headline)
                Text(error.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try Again") { service.refresh() }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 12)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: filter == .bugs ? "ant" : "lightbulb")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(emptyTitle)
                    .font(.headline)
                Text(emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 12)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch filter {
        case .all: "Nothing Reported Yet"
        case .bugs: "No Bugs Reported"
        case .features: "No Requests Yet"
        }
    }

    private var emptyMessage: LocalizedStringKey {
        switch filter {
        case .all:
            "Nobody has reported anything so far. If you have found something, you will be first."
        case .bugs:
            "Nothing is on the list as broken. That is not a promise that nothing is."
        case .features:
            "Nobody has asked for anything yet. There is no wrong thing to ask for."
        }
    }

    // MARK: - Footer

    private var listFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if service.didTruncate {
                Text("Only the most recently updated items are shown here. The full list is on GitHub.")
            }
            Text("This list is read straight from the project's public issues on GitHub. Reading it needs no account and sends nothing about you.")
            if let updated = service.lastUpdated {
                Text(
                    Loc.text(
                        "Updated %@",
                        updated.formatted(date: .abbreviated, time: .shortened)
                    )
                )
            }
        }
    }
}

// MARK: - One item in the list

struct CommunityIssueRow: View {
    let issue: CommunityIssue

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: issue.category.systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Neo.accent)
                .frame(width: 20, height: 20)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(issue.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 4)

                    // Verbatim, so an issue number is a label rather than a
                    // quantity: interpolating the Int makes SwiftUI localize
                    // it and #3968 is drawn as "#3,968".
                    Text(verbatim: "#\(issue.number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if let summary = issue.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                // The status is said in words, in a face that is doing nothing
                // else on this screen, rather than drawn as a coloured dot.
                // Somebody reading it with colour-blindness, at a glance, or
                // out loud with VoiceOver gets the same thing.
                HStack(spacing: 5) {
                    Text(LocalizedStringKey(issue.category.label))
                    Text(verbatim: "·")
                    Text(LocalizedStringKey(issue.status.label))
                        .font(.caption.italic())
                        .fontDesign(.serif)
                        .foregroundStyle(.primary)
                    Text(verbatim: "·")
                    Text(issue.updatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        Text(
            Loc.text(
                "%@. %@, %@. Issue %@, updated %@.",
                issue.title,
                Loc.text(issue.category.label),
                Loc.text(issue.status.label),
                "\(issue.number)",
                issue.updatedAt.formatted(.relative(presentation: .named))
            )
        )
    }
}
