import SwiftUI

/// One roadmap item, read inside the app.
///
/// Native rather than a web view onto github.com. Somebody checking whether
/// their bug is known should not have to load a developer site, and the parts
/// of a GitHub issue that matter to them — what it says, where it has got to,
/// when it last moved — are a short list. The whole thread, with its comments
/// and its commits, is one tap away for anybody who wants it.
struct CommunityIssueDetailView: View {
    let issue: CommunityIssue

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading
                facts
                if let summary = issue.summary {
                    description(summary)
                }
                attributionCard
                if let url = issue.webURL {
                    openOnGitHub(url)
                }
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
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

            // Plain text rather than rendered Markdown. The body is written by
            // whoever filed it, and running it through a renderer would mean
            // deciding what to do about images and links somebody else chose.
            Text(summary)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
