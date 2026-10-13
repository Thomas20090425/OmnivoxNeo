import SwiftUI

/// Who made this, and why.
///
/// An unofficial app asks a student to type their college password into
/// something no institution stands behind, and the honest answer to "who is
/// behind this?" cannot be a blank. This page is that answer: a name, a face,
/// what the person has built before, and what they were trying to do here.
/// Parents end up reading it as often as students do, so it is written for
/// somebody who has never heard of any of it.
///
/// What is deliberately **not** here: no address, no telephone number, nothing
/// that is not already a public way to reach somebody.
struct AboutTheAuthorView: View {
    @Environment(\.openURL) private var openURL

    private static let email = "yuecheng.ma@dawsoncollege.qc.ca"
    private static let instagramHandle = "thomas_ycma"
    /// The web address rather than the `instagram://` scheme, so it opens the
    /// Instagram app when it is installed and the profile in a browser when it
    /// is not, instead of failing silently on a device without it.
    private static let instagramURL = URL(string: "https://www.instagram.com/thomas_ycma/")!

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                portrait
                story
                links
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - The face and the name

    private var portrait: some View {
        VStack(spacing: 14) {
            // Filled into the circle through a clear container rather than a
            // plain `.frame`, so the crop can be nudged: filling a tall
            // portrait into a square centres on the middle of the photograph,
            // which here is the chest. The offset brings the face to the
            // middle of the circle, where a face belongs.
            Color.clear
                .frame(width: 132, height: 132)
                .overlay(
                    Image("Thomas")
                        .resizable()
                        // Taken on an iPhone and still carrying its gain map,
                        // so on a display that can show it, it is shown.
                        .allowedDynamicRange(.high)
                        .scaledToFill()
                        .offset(y: 12)
                )
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Neo.separator, lineWidth: 0.5))
                .accessibilityLabel("A photograph of Yuecheng Ma")

            VStack(spacing: 3) {
                Text("Yuecheng (Thomas) Ma")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Dawson College · Commerce, first year")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 24)
        .padding(.horizontal, 20)
    }

    // MARK: - The words

    private var story: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hi. I'm a first-year student at Dawson, and I wrote this app.")
                .font(.body.weight(.medium))

            Text("Before Dawson I was at Kells Academy, where most of my spare time went into building things — a login system that replaces passwords with a physical key you carry, a network gateway for places with poor internet, and, earlier on, a robot that cut grass on its own. Those took me to the Montreal regional science fair, the Quebec provincial competition, and in 2026 to the international fair with Team Canada.")

            Text("I also run a small company, Tjokas Technologies, doing iOS and web work and hosting servers for a few clients. Omnivox Neo is not part of that. Nobody is paying for it, nothing in it is for sale, and it collects nothing about you.")

            VStack(alignment: .leading, spacing: 8) {
                Text("Why I made it")
                    .font(.headline)

                Text("Everything a student needs is already in Omnivox. Reaching any of it takes too long. I wanted my timetable on the Home Screen, my grades in a list I could actually read, and my messages somewhere that behaves like mail — the same information, with the detours taken out. Simpler to get to, and better to look at. That is the whole of it.")
            }
            .padding(.top, 2)

            Text("If something here is broken, or you want something added, the feedback form reaches me directly.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
        .padding(.horizontal, 16)
    }

    // MARK: - Two ways to reach him

    private var links: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                contactRow(
                    title: "Email",
                    detail: Self.email,
                    systemImage: "envelope.fill"
                ) {
                    if let url = URL(string: "mailto:\(Self.email)") { openURL(url) }
                }

                Divider().padding(.leading, 59)

                contactRow(
                    title: "Instagram",
                    detail: "@\(Self.instagramHandle)",
                    systemImage: "camera.fill"
                ) {
                    openURL(Self.instagramURL)
                }
            }
            .neoCard()

            Text("A follow is welcome, and entirely optional.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 56)
    }

    private func contactRow(
        title: LocalizedStringKey,
        detail: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsIcon(systemImage: systemImage, tint: Neo.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
