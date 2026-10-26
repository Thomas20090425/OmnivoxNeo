import SwiftUI

struct LoginView: View {
    @ObservedObject var model: AppModel

    @State private var password = ""
    @State private var showsPassword = false
    @State private var showsInstitutionMessage = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case studentID
        case password
    }

    @ObservedObject private var acceptance = AgreementAcceptance.shared

    private var canSubmit: Bool {
        model.loginStudentID.count == 7
            && !password.isEmpty
            && !model.isBusy
            // Nothing reaches the college until the terms have been accepted.
            // Gating the button rather than warning afterwards keeps the
            // agreement a precondition instead of a formality.
            && acceptance.hasAcceptedCurrent
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                if model.canCancelAccountSetup {
                    addAccountBar
                }

                header
                credentials
                AgreementConsentRow(acceptance: acceptance)
                submit
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(NeoBackground())
        .alert("One School for Now", isPresented: $showsInstitutionMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Omnivox Neo currently supports \(model.institution.displayName). More institutions are planned.")
        }
    }

    /// Shown only while adding an account, so the flow is never a dead end:
    /// someone who opened it by mistake can back out to the account they were
    /// already using.
    private var addAccountBar: some View {
        HStack {
            Button {
                Task { await model.cancelAccountSetup() }
            } label: {
                Label("Cancel", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.body)
            }
            .accessibilityHint("Stops adding an account and returns to the previous one")

            Spacer()

            Text("Adding Account")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var header: some View {
        VStack(spacing: 14) {
            NeoLogo()

            VStack(spacing: 4) {
                Text("Omnivox Neo")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)

                Text(model.institution.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 6)
    }

    /// Labels sit above their fields so they remain readable at accessibility
    /// text sizes and on the Duo's narrow outer display.
    private var credentials: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Student ID")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 10) {
                    TextField("0000000", text: $model.loginStudentID)
                        .focused($focusedField, equals: .studentID)
                        .studentIDInputTraits()
                        .submitLabel(.next)
                        .onChange(of: model.loginStudentID) { _, newValue in
                            let normalized = AppModel.normalizedStudentID(newValue)
                            if normalized != newValue {
                                model.loginStudentID = normalized
                            }
                        }
                        .onSubmit { focusedField = .password }

                    if model.loginStudentID.count == 7 {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Student ID is complete")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)

            Divider().padding(.leading, 16)

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 10) {
                    Group {
                        if showsPassword {
                            TextField("Required", text: $password)
                        } else {
                            SecureField("Required", text: $password)
                        }
                    }
                    .focused($focusedField, equals: .password)
                    .omnivoxPasswordInputTraits()
                    .submitLabel(.go)
                    .onSubmit { submitIfPossible() }

                    Button {
                        showsPassword.toggle()
                    } label: {
                        Image(systemName: showsPassword ? "eye.slash" : "eye")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)

            Divider().padding(.leading, 16)

            Button {
                showsInstitutionMessage = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Institution")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        Text(model.institution.displayName)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .neoCard()
    }

    private var submit: some View {
        VStack(spacing: 12) {
            if let error = model.loginError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            Button(action: submitIfPossible) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Text("Sign In")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSubmit)

            Text("Your password is stored only on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .animation(.easeInOut(duration: 0.2), value: model.loginError)
        .onChange(of: model.loginError) { _, error in
            if error != nil {
                focusedField = .password
            }
        }
        .onAppear {
            password = ""
            showsPassword = false
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                focusedField = model.loginStudentID.count == 7 ? .password : .studentID
            }
        }
    }

    private func submitIfPossible() {
        guard canSubmit else { return }
        focusedField = nil
        let submittedPassword = password
        password = ""
        model.signIn(studentID: model.loginStudentID, password: submittedPassword)
    }
}
