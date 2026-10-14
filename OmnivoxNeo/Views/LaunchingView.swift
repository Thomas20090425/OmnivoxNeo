import SwiftUI

struct LaunchingView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    var body: some View {
        VStack(spacing: 22) {
            NeoLogo(size: 76)

            VStack(spacing: 7) {
                Text("Omnivox Neo")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("Logging in...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .tint(Neo.accent)
        }
        .padding(40)
    }
}
