import SwiftUI

struct LaunchingView: View {
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
