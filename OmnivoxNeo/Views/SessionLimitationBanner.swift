import SwiftUI

/// What every screen needs to know about how much of the app is real right now.
///
/// Put in the environment rather than passed down, because the answer is the
/// same everywhere and the screens that need it are scattered: a compose
/// button, a refresh, a folder that has never been fetched.
private struct SessionLimitationKey: EnvironmentKey {
    static let defaultValue: SessionLimitation? = nil
}

extension EnvironmentValues {
    var sessionLimitation: SessionLimitation? {
        get { self[SessionLimitationKey.self] }
        set { self[SessionLimitationKey.self] = newValue }
    }
}

extension View {
    /// Turns a control off, and says so, when it needs the college.
    ///
    /// Both states are covered: offline cannot reach OmniVox, and a countdown
    /// means OmniVox has already refused this session — so the request that
    /// started the countdown is exactly the one that would be sent again.
    @ViewBuilder
    func requiresTheCollege(_ limitation: SessionLimitation?) -> some View {
        if limitation == nil {
            self
        } else {
            self
                .disabled(true)
                .opacity(0.35)
                .accessibilityHint(Text("Not available until you are back online"))
        }
    }
}

/// The bar across the top saying the app is running on what it already had.
///
/// Two different messages that must never be mistaken for each other. Offline
/// is nobody's fault and clears itself. A countdown is OmniVox refusing this
/// session, and it ends in a real sign-in whether or not anybody presses
/// anything — so it says exactly how long is left, and offers the way out now.
struct SessionLimitationBanner: View {
    let limitation: SessionLimitation
    let onSignInNow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if limitation.deadline != nil {
                Button(action: onSignInNow) {
                    Text("Sign In")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        limitation.deadline == nil ? "wifi.slash" : "person.crop.circle.badge.exclamationmark.fill"
    }

    private var tint: Color {
        limitation.deadline == nil ? .secondary : .orange
    }

    private var title: LocalizedStringKey {
        limitation.deadline == nil ? "Offline" : "Sign in again"
    }

    @ViewBuilder
    private var detail: some View {
        if let deadline = limitation.deadline {
            // A live countdown, drawn by SwiftUI rather than ticked by a timer
            // of our own — it keeps running correctly while the app is away.
            HStack(spacing: 4) {
                Text("OmniVox needs you to sign in.")
                Text(timerInterval: Date()...max(deadline, Date().addingTimeInterval(1)), countsDown: true)
                    .monospacedDigit()
            }
        } else {
            Text("Showing what is saved on this device.")
        }
    }
}
