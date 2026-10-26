import SwiftUI

struct VerificationView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var lastAutoSubmittedCode: String?
    @State private var showsLogOutConfirmation = false
    // Plain state, not @FocusState: the code field is a UITextField that owns
    // its own first-responder status and reports it back through this binding.
    @State private var codeIsFocused = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if model.autoTOTPInProgress {
                    automaticSignIn
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NeoBackground())
            // "Verify it's you" over a screen that is not verifying anything —
            // the college is holding sign-in up and there is nothing here to
            // prove — reads as one more step in a flow that has in fact
            // stopped.
            .navigationTitle(
                model.verificationState.mode == .schoolActionRequired
                    ? Text("Before You Sign In")
                    : Text("Verify It’s You")
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        model.usePasswordInstead()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if model.verificationIsBusy {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: model.verificationState.mode) { _, _ in resetCode() }
        .onChange(of: model.verificationState.destination) { _, _ in resetCode() }
        .alert("Log Out of OmniVox?", isPresented: $showsLogOutConfirmation) {
            Button("Log Out", role: .destructive) { model.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved password, Face ID setting, trusted-device status and cached information from this device. Your student ID stays prefilled.")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let error = model.autoTOTPError {
                    automaticSignInFailed(error)
                }

                switch model.verificationState.mode {
                case .loading:
                    loadingContent
                case .code:
                    codeContent
                case .methods:
                    methodsContent
                case .unavailable:
                    unavailableContent
                case .schoolActionRequired:
                    schoolActionContent
                }

                if let error = model.verificationState.errorMessage {
                    footnote(error, systemImage: "exclamationmark.circle.fill", tint: .red)
                }

                if let notice = model.verificationNotice {
                    footnote(notice, systemImage: "checkmark.circle.fill", tint: Neo.accent)
                }
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func footnote(_ message: String, systemImage: String, tint: Color) -> some View {
        Label(message, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private var loadingContent: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(model.verificationState.instruction)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .neoCard()
    }

    private var codeContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(model.verificationState.instruction)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                if let destination = model.verificationState.destination {
                    Text(destination)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            // The field carries its own emphasis through size and spacing, so
            // it needs no caps label above it and no heavy outline around it.
            VerificationCodeField(
                text: $code,
                isFocused: $codeIsFocused,
                onSubmit: submitCode
            )
            .frame(height: 56)
            .background(Neo.inset, in: RoundedRectangle(cornerRadius: Neo.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Neo.controlRadius, style: .continuous)
                    .stroke(Neo.accent, lineWidth: codeIsFocused ? 2 : 0)
            }
            .onChange(of: code) { _, newValue in
                let normalized = AppModel.normalizedVerificationCode(newValue)
                if normalized != newValue {
                    code = normalized
                    return
                }
                if normalized.count < 6 {
                    lastAutoSubmittedCode = nil
                } else if lastAutoSubmittedCode != normalized,
                          !model.verificationIsBusy, scenePhase == .active {
                    lastAutoSubmittedCode = normalized
                    submitCode()
                }
            }

            Button("Verify", action: submitCode)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(code.count != 6 || model.verificationIsBusy)

            VStack(spacing: 14) {
                if model.verificationState.canRequestNewCode {
                    Button("Send a New Code") {
                        resetCode()
                        model.requestNewVerificationCode()
                    }
                }

                if model.verificationState.canChooseAnotherMethod {
                    Button("Use Another Method") {
                        codeIsFocused = false
                        model.showVerificationMethods()
                    }
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.top, 2)
        }
        .padding(20)
        .neoCard()
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Wait for the screen transition to attach the native input.
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard model.verificationState.mode == .code,
                  !model.verificationIsBusy,
                  !showsLogOutConfirmation else { return }
            codeIsFocused = true
        }
    }

    private var methodsContent: some View {
        VStack(spacing: 16) {
            Text("Choose how you’d like to verify.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(model.verificationState.methods.enumerated()), id: \.element.id) { index, method in
                    if index > 0 {
                        Divider().padding(.leading, 56)
                    }

                    Button {
                        model.chooseVerificationMethod(method)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: method.kind.systemImage)
                                .font(.body)
                                .foregroundStyle(Neo.accent)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(method.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)

                                if !method.detail.isEmpty {
                                    Text(method.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.verificationIsBusy)
                }
            }
            .neoCard()

            VStack(spacing: 14) {
                if model.verificationState.canGoBack {
                    Button("Back") { model.returnToVerificationCode() }
                        .font(.subheadline.weight(.medium))
                }

                Button("Log Out", role: .destructive) {
                    showsLogOutConfirmation = true
                }
                .font(.subheadline.weight(.medium))
                .disabled(model.verificationIsBusy)
            }
            .padding(.top, 2)
        }
    }

    private var unavailableContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)

            Text(model.verificationState.instruction)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Return to Sign In") { model.usePasswordInstead() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)

            // The way out when the one above keeps arriving back here.
            //
            // "Return to sign in" deliberately keeps this device trusted, which
            // is right almost always and exactly wrong when the trusted state
            // is itself what sign-in is choking on: the next attempt goes
            // straight back into the same page, and the only remaining escape
            // was to delete the app. This forgets everything and costs one more
            // two-factor code.
            Button("Start Again From Scratch") { model.startAgainFromScratch() }
                .font(.subheadline)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .neoCard()
    }

    /// The college is waiting on something, and it is not this app's to do.
    ///
    /// Nothing here throws anything away. The saved password stays, the trusted
    /// device stays, and "Try Again" is just the sign-in over again — because
    /// what is in the way is on the college's side of the glass, and charging
    /// the student a fresh two-factor code for it would be charging them for
    /// somebody else's errand.
    private var schoolActionContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.title)
                .foregroundStyle(.orange)

            Text(model.verificationState.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(model.verificationState.instruction)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(Loc.text("Open the %@ Website", model.institution.displayName)) {
                openURL(model.institution.origin)
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 4)

            // Underneath, deliberately. Going to the website is the thing that
            // fixes this; coming back and trying again is what you do after.
            Button("Try Again") { model.tryPortalSignInAgain() }
                .font(.subheadline.weight(.medium))
                .disabled(model.verificationIsBusy)

            if let address = model.unrecognizedPageAddress {
                // The page OmniVox actually stopped on. Small, and last — it is
                // not for the student, it is for whoever they show it to when
                // the website turns out not to explain itself either.
                Text(address)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .neoCard()
    }

    private func submitCode() {
        guard code.count == 6, !model.verificationIsBusy else { return }
        codeIsFocused = false
        model.submitVerificationCode(code)
    }

    private func resetCode() {
        code = ""
        lastAutoSubmittedCode = nil
    }

    // MARK: - Automatic sign-in

    private var automaticSignIn: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text("Signing you in")
                    .font(.headline)

                Text(model.autoTOTPStep ?? Loc.text("Using your saved authenticator."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }

            // Always an escape hatch: a portal that stalls must never leave the
            // student staring at a spinner with nothing to press.
            Button("Enter the Code Myself") {
                model.cancelAutoTOTPLogin()
            }
            .font(.subheadline.weight(.medium))
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 440)
    }

    private func automaticSignInFailed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Automatic sign-in didn’t work", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .neoCard()
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.orange)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                .padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
    }
}
