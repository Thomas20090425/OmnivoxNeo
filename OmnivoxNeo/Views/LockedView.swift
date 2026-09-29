import SwiftUI

struct LockedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .fill(Neo.accent.opacity(0.11))
                    .frame(width: 112, height: 112)

                Image(systemName: model.biometricCapability.systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(Neo.accent)
            }

            VStack(spacing: 8) {
                Text("OmniVox Neo locked")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Use \(model.biometricCapability.name) or your device passcode to continue.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            if let error = model.sessionError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button {
                    Task { await model.unlock() }
                } label: {
                    HStack(spacing: 9) {
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: model.biometricCapability.systemImage)
                            Text("Unlock")
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy)

                Button("Use OmniVox password") {
                    model.usePasswordInstead()
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Neo.accent)
                .disabled(model.isBusy)
            }
        }
        .frame(maxWidth: 420)
        .padding(30)
        .neoCard()
        .padding(24)
    }
}
