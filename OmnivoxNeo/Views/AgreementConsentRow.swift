import SwiftUI

/// The one thing a student has to agree to before this app touches their
/// account.
///
/// Unticked by default and never pre-ticked, because a box that arrives
/// already ticked is not consent in any jurisdiction that has thought about
/// it. Sign In stays disabled until it is ticked, so agreeing is a thing that
/// was done rather than a thing that was defaulted.
///
/// It says two separate things on purpose. Agreeing to *this* app's terms does
/// not replace the college's own conditions — those keep applying to the
/// account whatever is used to reach it — and a student who only understood
/// one of those would have understood the wrong one.
struct AgreementConsentRow: View {
    @ObservedObject var acceptance: AgreementAcceptance
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if acceptance.hasAcceptedCurrent {
                    acceptance.withdraw()
                } else {
                    acceptance.accept()
                }
            } label: {
                Image(
                    systemName: acceptance.hasAcceptedCurrent
                        ? "checkmark.square.fill"
                        : "square"
                )
                .font(.title3)
                .foregroundStyle(acceptance.hasAcceptedCurrent ? Neo.accent : Color.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("I accept the agreements")
            .accessibilityAddTraits(acceptance.hasAcceptedCurrent ? [.isSelected] : [])

            VStack(alignment: .leading, spacing: 6) {
                consentSentence
                collegeSentence
            }
        }
        .padding(.horizontal, 2)
        .animation(.easeInOut(duration: 0.15), value: acceptance.hasAcceptedCurrent)
    }

    private var consentSentence: some View {
        (
            Text("I have read and accept the ")
                + link("End User Licence Agreement", LegalDocuments.eulaURL)
                + Text(" and the ")
                + link("Privacy Policy", LegalDocuments.privacyURL)
                + Text(".")
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var collegeSentence: some View {
        (
            Text("Omnivox Neo is not made by, affiliated with, or endorsed by your college or by Skytech. Your ")
                + link("college's own Omnivox conditions", LegalDocuments.collegeTermsURL)
                + Text(" still apply to your account.")
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Reads as a link either way, and only *is* one once the document exists.
    ///
    /// The alternative — a live link to a page that has not been published —
    /// is a dead end dressed up as a destination. This keeps the sentence the
    /// final wording while the pages are still being written.
    private func link(_ label: String, _ url: URL?) -> Text {
        guard let url else {
            return Text(label).foregroundColor(Neo.accent)
        }
        return Text(.init("[\(label)](\(url.absoluteString))"))
    }
}
