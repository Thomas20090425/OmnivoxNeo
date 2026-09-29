//
//  FirstTimeTOTPPromptView.swift
//  OmnivoxNeo
//
//  Prompt first-time users to set up built-in authenticator
//

import SwiftUI

/// The one-time offer to register this device as an authenticator.
///
/// One time, now, for real. "Maybe Later" used to write
/// `HasShownTOTPSetupPrompt_<studentID>` while the gate that decides whether to
/// ask read `totp.prompt-shown.<profileUUID>` — two different keys, so the
/// answer was recorded somewhere nobody looked and the question came back on
/// every launch, every sign-in and every Face ID unlock. Declining now goes
/// through `AppModel`, which owns both the flag and the question.
struct FirstTimeTOTPPromptView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSetup = false
    @State private var hasDeclined = false

    var body: some View {
        Group {
            if hasDeclined {
                declined
            } else {
                offer
            }
        }
        .padding(24)
        .animation(.easeInOut(duration: 0.2), value: hasDeclined)
        .sheet(isPresented: $showSetup) {
            TOTPGuidedSetupView(model: model)
                .onDisappear {
                    // Only a finished setup closes this. Backing out of the
                    // guided flow returns here, where "Maybe Later" is still
                    // an option — it should not silently count as declining.
                    if model.hasTOTPSecret() { dismiss() }
                }
        }
    }

    private var offer: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "checkmark.shield.fill")
                .font(.system(.largeTitle, design: .default, weight: .regular))
                .foregroundStyle(Neo.live)

            // Title
            Text("Set Up OmniVox Neo Authenticator?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            // Description
            VStack(spacing: 16) {
                Text("Skip 2FA on this device next time you log in by setting up the OmniVox Neo Authenticator.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Neo.live)
                        Text("No need to enter codes manually on this device")
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(Neo.accent)
                        Text("Your OmniVox validation methods stay unchanged")
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "iphone")
                            .foregroundStyle(Neo.accent)
                        Text("Only works on this device for security")
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Neo.surface, in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer()

            // Buttons
            VStack(spacing: 12) {
                Button {
                    showSetup = true
                } label: {
                    Text("Set Up Now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    model.markTOTPPromptShown()
                    hasDeclined = true
                } label: {
                    Text("Maybe Later")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
    }

    /// The acknowledgement, so "not now" is answered rather than just obeyed.
    ///
    /// Saying where the setting lives is the whole point: the offer is not
    /// coming back, and a student who changes their mind in October should not
    /// have to hunt for it.
    private var declined: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(.largeTitle, design: .default, weight: .regular))
                .foregroundStyle(Neo.live)

            Text("We won’t ask again")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("You can turn the built-in authenticator on whenever you like. Open the Account tab, tap App Settings, then Set Up Built-in Authenticator.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}
