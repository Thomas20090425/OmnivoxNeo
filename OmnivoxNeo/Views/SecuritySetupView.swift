import SwiftUI

struct SecuritySetupView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var model: AppModel
    @State private var protectsSchedule = true
    @State private var keepsInformationOnDevice = true

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

            // Offered second, and only alive when the first one is.
            //
            // The saved copy and the scan are one mechanism: the copy is what
            // makes the app instant and usable with no signal, and the scan is
            // the only thing standing in front of it. Without the lock there
            // is nothing guarding it, so the switch goes dead rather than
            // pretending the choice is still there.
            HStack(spacing: 14) {
                Image(systemName: "bolt.fill")
                    .font(.title2)
                    .foregroundStyle(Neo.accent)
                    .frame(width: 42, height: 42)
                    .background(Neo.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Instant open and offline access")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Keeps a copy of your timetable and recent activity on this device, so the app opens straight away and still works with no signal. It stays on this phone, is never sent anywhere, and only opens after \(model.biometricCapability.name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle("", isOn: $keepsInformationOnDevice)
                    .labelsHidden()
                    .tint(Neo.accent)
                    .disabled(!protectsSchedule || !model.biometricCapability.isAvailable)
            }
            .padding(17)
            .background(Color.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .opacity(protectsSchedule && model.biometricCapability.isAvailable ? 1 : 0.4)
            // Turning the lock off takes this with it rather than leaving a
            // switch that says yes and means nothing.
            .onChange(of: protectsSchedule) { _, locked in
                if !locked { keepsInformationOnDevice = false }
            }

            Button("Continue") {
                Task {
                    model.setFastUnlockEnabled(protectsSchedule && keepsInformationOnDevice)
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
            keepsInformationOnDevice = model.biometricCapability.isAvailable
        }
    }
}
