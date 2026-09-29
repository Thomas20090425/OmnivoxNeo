import SwiftUI

struct SecuritySetupView: View {
    @ObservedObject var model: AppModel
    @State private var protectsSchedule = true

    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle()
                    .fill(Neo.live.opacity(0.16))
                    .frame(width: 108, height: 108)

                Image(systemName: "checkmark.shield.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Neo.live)
            }

            VStack(spacing: 8) {
                Text("You’re signed in")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)

                Text("Choose how you’d like to protect OmniVox Neo on this device.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Image(systemName: model.biometricCapability.systemImage)
                    .font(.title2)
                    .foregroundStyle(Neo.accent)
                    .frame(width: 42, height: 42)
                    .background(Neo.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Require \(model.biometricCapability.name)")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Securely saves your OmniVox password for automatic sign-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $protectsSchedule)
                    .labelsHidden()
                    .tint(Neo.accent)
                    .disabled(!model.biometricCapability.isAvailable)
            }
            .padding(17)
            .background(Color.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

            Button("Continue") {
                Task {
                    await model.completeSecuritySetup(requireBiometricLock: protectsSchedule)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.securitySetupIsBusy)

            if model.securitySetupIsBusy {
                ProgressView("Confirming…")
                    .tint(Neo.accent)
            } else if let error = model.securitySetupError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 460)
        .padding(28)
        .neoCard()
        .padding(24)
        .onAppear {
            protectsSchedule = model.biometricCapability.isAvailable
        }
    }
}
