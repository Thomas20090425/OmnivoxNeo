import SwiftUI

/// One roadmap item, read inside the app.
///
/// Native rather than a web view onto github.com. Somebody checking whether
/// their bug is known should not have to load a developer site, and the parts
/// of a GitHub issue that matter to them — what it says, where it has got to,
/// when it last moved — are a short list. The whole thread, with its comments
/// and its commits, is one tap away for anybody who wants it.
struct CommunityIssueDetailView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    let issue: CommunityIssue
    var service: CommunityFeedbackService?

    @Environment(\.openURL) private var openURL
    @State private var comments: [CommunityIssueComment] = []
    @State private var isLoadingComments = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading
                facts
                if let summary = issue.summary {
                    description(summary)
                }
                attributionCard
                replies
                if let url = issue.webURL {
                    openOnGitHub(url)
                }
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .task {
            guard let service, issue.commentCount > 0, comments.isEmpty else { return }
            isLoadingComments = true
            comments = await service.comments(for: issue)
            isLoadingComments = false
        }
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle(Text(verbatim: "#\(issue.number)"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Title

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: issue.category.systemImage)
                Text(LocalizedStringKey(issue.category.label))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Where it has got to

    private var facts: some View {
        VStack(spacing: 0) {
            // Status in words, in serif italic — the one face used nowhere
            // else on this screen, so it reads as a state rather than as a
            // decoration, and carries no colour anybody has to be able to see.
            factRow(label: "Status") {
                Text(LocalizedStringKey(issue.status.label))
                    .font(.callout.italic())
                    .fontDesign(.serif)
            }

            if let assigned = issue.assignedToLabel {
                Divider().padding(.leading, 16)
                factRow(label: "Assigned to") {
                    Text(verbatim: assigned)
                        .foregroundStyle(Neo.accent)
                }
            }

            Divider().padding(.leading, 16)

            factRow(label: "Last updated") {
                Text(issue.updatedAt.formatted(date: .abbreviated, time: .shortened))
            }

            Divider().padding(.leading, 16)

            factRow(label: "Reported") {
                Text(issue.createdAt.formatted(date: .abbreviated, time: .omitted))
            }

            if issue.commentCount > 0 {
                Divider().padding(.leading, 16)
                factRow(label: "Replies") {
                    Text("\(issue.commentCount)")
                }
            }
        }
        .neoCard()
        .overlay(alignment: .bottom) { EmptyView() }
    }

    private func factRow<Value: View>(
        label: LocalizedStringKey,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value()
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - What they wrote

    private func description(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What was reported")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Rendered rather than shown raw. What people type is Markdown —
            // it is what GitHub stores and what they see reading their own
            // report back — so showing the asterisks and backticks would read
            // as the app having mangled it.
            CommunityMarkdownText(markdown: summary)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }

    // MARK: - Who sent it

    private var attributionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: issue.attribution == nil ? "person.crop.circle.dashed" : "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                if let name = issue.attribution {
                    Text(verbatim: name)
                        .font(.callout.weight(.medium))
                    Text("Named themselves when they sent this in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Anonymous contributor")
                        .font(.callout.weight(.medium))
                    Text("The name box is optional, and this one was left empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }

    // MARK: - What happened next

    /// The replies, which are usually where the answer actually is.
    ///
    /// A bug marked Completed with a reply saying what was fixed and in which
    /// build is a different thing from the word "Completed" on its own, and
    /// until now the app showed the word and hid the reply — so the only way
    /// to find out what had happened to your own report was to leave for
    /// github.com.
    @ViewBuilder
    private var replies: some View {
        if issue.commentCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Replies")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if comments.isEmpty {
                    HStack(spacing: 8) {
                        if isLoadingComments {
                            ProgressView().controlSize(.small)
                            Text("Loading the replies…")
                        } else {
                            Text("The replies could not be loaded. They are on GitHub.")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                        if index > 0 { Divider() }
                        reply(comment)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neoCard()
        }
    }

    private func reply(_ comment: CommunityIssueComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: comment.author)
                    .font(.footnote.weight(.semibold))
                if comment.isFromDeveloper {
                    // Said in words rather than drawn as a coloured badge: it
                    // is the one thing on this card worth knowing before
                    // reading the reply, and it should survive being read
                    // aloud or in greyscale.
                    Text("Developer")
                        .font(.caption.italic())
                        .fontDesign(.serif)
                        .foregroundStyle(Neo.accent)
                }
                Spacer(minLength: 6)
                Text(comment.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            CommunityMarkdownText(markdown: comment.body, font: .footnote)
                .textSelection(.enabled)
        }
    }

    // MARK: - The way out

    private func openOnGitHub(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openURL(url)
            } label: {
                Label("Read the Full Thread on GitHub", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("Opens in your browser. Replies, related changes and the full history live there.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .padding(.top, 2)
    }
}
