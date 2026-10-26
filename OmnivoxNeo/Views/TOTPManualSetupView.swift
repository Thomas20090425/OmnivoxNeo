//
//  TOTPManualSetupView.swift
//  OmnivoxNeo
//
//  Guided manual TOTP setup
//

import SwiftUI

struct TOTPManualSetupView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentStep = 0
    @State private var totpSecret = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private let steps = [
        "Open OmniVox Settings",
        "Navigate to 2-Step Validation",
        "Add Authenticator App",
        "Copy the Secret Code",
        "Enter Secret Below"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Progress
                HStack(spacing: 8) {
                    ForEach(0..<steps.count, id: \.self) { index in
                        Circle()
                            .fill(index <= currentStep ? Neo.accent : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top)

                ScrollView {
                    VStack(spacing: 24) {
                        stepContent
                    }
                    .padding()
                }

                // Navigation
                HStack(spacing: 12) {
                    if currentStep > 0 {
                        Button("Back") {
                            withAnimation {
                                currentStep -= 1
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if currentStep < steps.count - 1 {
                        Button("Next") {
                            withAnimation {
                                currentStep += 1
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Complete Setup") {
                            completeSetup()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(totpSecret.isEmpty || isProcessing)
                    }
                }
                .padding()
            }
            .navigationTitle("Setup Authenticator")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            step1Content
        case 1:
            step2Content
        case 2:
            step3Content
        case 3:
            step4Content
        case 4:
            step5Content
        default:
            EmptyView()
        }
    }

    private var step1Content: some View {
        VStack(spacing: 16) {
            Image(systemName: "gear")
                .font(.largeTitle)
                .foregroundStyle(Neo.accent)

            Text("Open OmniVox Settings")
                .font(.title2.bold())

            Text("In the OmniVox web interface, navigate to your account settings. We'll walk you through adding Neo as an authenticator.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var step2Content: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.checkered")
                .font(.largeTitle)
                .foregroundStyle(Neo.live)

            Text("Navigate to 2-Step Validation")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Go to **My Account** (bottom of menu)")
                Text("2. Select **Personal Profile**")
                Text("3. Click **Two-step verification**")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Neo.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var step3Content: some View {
        VStack(spacing: 16) {
            Image(systemName: "plus.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(Neo.accent)

            Text("Add Authenticator App")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Click the **Add** button")
                Text("2. Choose **Authenticator Application**")
                Text("3. Click **\"I cannot scan this code\"**")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Neo.surface, in: RoundedRectangle(cornerRadius: 12))

            Text("This will reveal the secret code you need.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var step4Content: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.clipboard")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Copy the Secret Code")
                .font(.title2.bold())

            Text("You'll see a long code like:")
                .foregroundStyle(.secondary)

            Text("ZB43CZ3ARAX7C25B...")
                .font(.system(.body, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            Text("Click the **Copy** button next to the code.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var step5Content: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Enter Secret Below")
                .font(.title2.bold())

            TextField("Paste secret code here", text: $totpSecret)
                .textFieldStyle(.roundedBorder)
                .authenticatorSecretInputTraits()
                .font(.system(.body, design: .monospaced))

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("After completing setup here, return to OmniVox and enter the 6-digit code that Neo generates to validate.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func completeSetup() {
        let cleaned = totpSecret.replacingOccurrences(of: " ", with: "").uppercased()

        guard !cleaned.isEmpty else {
            errorMessage = Loc.text("Please enter the secret code")
            return
        }

        isProcessing = true
        errorMessage = nil

        Task {
            do {
                // Validate the secret by trying to generate a code
                _ = try TOTPGenerator(secret: cleaned)

                // Get the current profile ID from the profile store
                guard let profileID = PortalProfileStore.shared.activeProfileID else {
                    await MainActor.run {
                        isProcessing = false
                        errorMessage = Loc.text("No active profile found.")
                    }
                    return
                }

                // Save to vault
                let secret = TOTPSecret(
                    profileID: profileID,
                    secret: cleaned,
                    enrolledAt: Date()
                )

                let vault = TOTPVault(profileID: profileID)
                vault.save(secret)

                await MainActor.run {
                    isProcessing = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = Loc.text("Invalid secret code. Please check and try again.")
                }
            }
        }
    }
}

#Preview {
    TOTPManualSetupView(model: AppModel(startsAutomatically: false))
}
