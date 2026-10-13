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

    @State private var reading: LegalDocument?

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

            VStack(alignment: .leading, spacing: 7) {
                consentSentence
                collegeSentence
            }
        }
        .padding(.horizontal, 2)
        .animation(.easeInOut(duration: 0.15), value: acceptance.hasAcceptedCurrent)
        .sheet(item: $reading) { document in
            LegalDocumentSheet(document: document)
        }
    }

    /// Both documents open from here, from the copies carried in the app, so
    /// they can be read before agreeing and with no signal.
    private var consentSentence: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("I have read and accept the terms below.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                documentButton("End User Licence Agreement", .eula)
                documentButton("Privacy Policy", .privacy)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func documentButton(_ label: LocalizedStringKey, _ document: LegalDocument) -> some View {
        Button { reading = document } label: {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Neo.accent)
                .underline()
        }
        .buttonStyle(.plain)
    }

    private var collegeSentence: some View {
        (
            Text("Omnivox Neo is not made by, affiliated with, or endorsed by your college or by Skytech, and it is not a replacement for Omnivox. Your ")
                + Text(
                    .init("[college's own Omnivox conditions](\(LegalDocuments.collegeTermsURL?.absoluteString ?? ""))")
                )
                + Text(" still apply to your account.")
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
