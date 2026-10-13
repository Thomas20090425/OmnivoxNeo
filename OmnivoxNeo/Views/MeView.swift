import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MeView: View {
    @ObservedObject var model: AppModel

    @State private var showsProfileSwitcher = false
    @State private var showsRemoveAccountOptions = false
    @State private var reading: LegalDocument?
    @State private var isRemovingAccount = false
    @StateObject private var profileStore = PortalProfileStore.shared

    private var profile: PortalProfile? {
        model.activeProfile
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showsProfileSwitcher = true
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Neo.accent)
                                    .frame(width: 46, height: 46)

                                Text(profile?.monogram ?? "?")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile?.accountLabel ?? Loc.text("Account"))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(profile?.identityLabel ?? model.institution.displayName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            if profileStore.profiles.count > 1 {
                                Text("\(profileStore.profiles.count)")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Switches between accounts or adds one")
                } footer: {
                    Text("More than one student can use this device. Each account keeps its own schedule, password and authenticator.")
                }

                // The student's own college, and whatever it contributes.
                // Its own section above the app's settings, because "where is
                // room 4H.15" is a question about Dawson, not about this app.
                if !SchoolExtensions.destinations(for: model).isEmpty {
                    Section {
                        ForEach(SchoolExtensions.destinations(for: model)) { place in
                            NavigationLink {
                                place.content
                            } label: {
                                SettingsRowLabel(
                                    title: place.title,
                                    systemImage: place.systemImage,
                                    tint: Neo.accent
                                )
                            }
                        }
                    } header: {
                        Text(model.institution.displayName)
                    }
                }

                Section {
                    NavigationLink {
                        AppSettingsView(model: model)
                    } label: {
                        SettingsRowLabel(
                            title: "App Settings",
                            systemImage: "gearshape.fill",
                            tint: Neo.accent
                        )
                    }
                    .accessibilityHint("Opens application settings")

                    Button(role: .destructive) {
                        showsRemoveAccountOptions = true
                    } label: {
                        SettingsRowLabel(
                            title: "Log Out",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            tint: .red,
                            isDestructive: true
                        )
                    }
                    .disabled(isRemovingAccount)
                }

                // Reachable from inside the app, not only from the App Store
                // listing. Somebody wondering what this thing does with their
                // password should be able to find the answer in the app that
                // is holding it, and the App Store requires as much.
                Section {
                    Button { reading = .eula } label: {
                        SettingsRowLabel(
                            title: "End User Licence Agreement",
                            systemImage: "doc.text",
                            tint: Neo.accent
                        )
                    }
                    Button { reading = .privacy } label: {
                        SettingsRowLabel(
                            title: "Privacy Policy",
                            systemImage: "hand.raised",
                            tint: Neo.accent
                        )
                    }
                } header: {
                    Text("Legal")
                } footer: {
                    Text("Omnivox Neo is an independent app. It is not made by, affiliated with, or endorsed by your college or by Skytech, and it is not a replacement for Omnivox.")
                }

                Section {
                    EmptyView()
                } footer: {
                    AppVersionFooter()
                }
            }
            .scrollContentBackground(.hidden)
            .background(NeoBackground())
            .sheet(item: $reading) { document in
                LegalDocumentSheet(document: document)
            }
            .navigationTitle("Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
        .sheet(isPresented: $showsProfileSwitcher) {
            ProfileSwitcherView(
                profileStore: profileStore,
                currentProfileID: model.activeProfileID
            )
        }
        // Logging out and deleting are genuinely different outcomes, so the
        // choice is made here rather than buried behind a single destructive
        // button whose meaning the student has to guess.
        .confirmationDialog(
            Text(Loc.text("Log Out of %@?", profile?.accountLabel ?? Loc.text("this account"))),
            isPresented: $showsRemoveAccountOptions,
            titleVisibility: .visible
        ) {
            Button("Log Out, Keep Account") {
                Task { await removeAccount(deleting: false) }
            }
            Button("Delete Account", role: .destructive) {
                Task { await removeAccount(deleting: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Logging out keeps this account on the device. Your student ID stays prefilled and your saved authenticator still answers the verification code, so signing back in only needs your password.\n\nDeleting removes the account and its authenticator completely.")
        }
    }

    private func removeAccount(deleting: Bool) async {
        guard let profile else { return }
        isRemovingAccount = true
        defer { isRemovingAccount = false }

        model.endSession()

        if deleting {
            await ProfileEraser.erase(profile)
            profileStore.forgetProfile(profile.id)
        } else {
            await ProfileEraser.signOut(profile)
            profileStore.markSignedOut(profile.id)
        }

        profileStore.finishAccountRemoval(removed: profile, wasDeleted: deleting)
    }
}

private struct AppSettingsView: View {
    @ObservedObject var model: AppModel

    @State private var isUpdatingLock = false
    @State private var authenticationFailed = false
    @State private var pendingLockValue: Bool?
    @State private var totpSecret: TOTPSecret?
    @State private var showTOTPSetup = false
    @State private var showTOTPDeleteConfirmation = false
    @StateObject private var profileStore = PortalProfileStore.shared
    @ObservedObject private var language = AppLanguageStore.shared

    var body: some View {
        List {
            Section {
                Toggle(isOn: biometricLockBinding) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemImage: "faceid", tint: Neo.accent)

                        Text("Require Face ID")
                            .foregroundStyle(.primary)

                        if isUpdatingLock {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Neo.accent)
                .disabled(
                    isUpdatingLock
                        || (!model.biometricCapability.isAvailable && !model.biometricLockEnabled)
                )
            } header: {
                Text("Security")
            } footer: {
                if let error = model.securitySetupError, authenticationFailed {
                    Text(error)
                } else if authenticationFailed {
                    Text("Authentication was not completed.")
                } else {
                    Text("Face ID protects the OmniVox password used when a fresh sign-in is required.")
                }
            }

            Section {
                NavigationLink {
                    PersonalizationSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemImage: "paintpalette.fill", tint: Neo.accent)

                        Text("Personalization")
                            .foregroundStyle(.primary)

                        Spacer(minLength: 8)

                        Circle()
                            .fill(Neo.accent)
                            .frame(width: 18, height: 18)
                    }
                }
            } footer: {
                Text("Choose an accent colour and a wallpaper for this account.")
            }

            Section {
                Picker(selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.nativeName).tag(option)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemImage: "globe", tint: Neo.accent)

                        Text("Language")
                            .foregroundStyle(.primary)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Automatic follows your iPhone. Anything not yet translated appears in English.")
            }

            // What is kept on the phone, and what that buys.
            //
            // Its own section rather than a line inside another one: it is the
            // only setting in the app that decides whether the student's
            // information is written to the device at all, and somebody
            // looking for that should find it without reading the rest.
            Section {
                Toggle(isOn: Binding(
                    get: { model.keepsInformationOnDevice },
                    set: { model.setFastUnlockEnabled($0) }
                )) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemImage: "bolt.fill", tint: Neo.accent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Instant Open and Offline Access")
                                .foregroundStyle(.primary)
                            if !model.biometricLockEnabled {
                                Text("Needs \(model.biometricCapability.name)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .tint(Neo.accent)
                // Dead without the lock, because the lock is the only thing
                // standing in front of the saved copy.
                .disabled(!model.biometricLockEnabled)
            } header: {
                Text("On This Device")
            } footer: {
                if model.biometricLockEnabled {
                    Text("Keeps a copy of your timetable and recent activity on this iPhone so Neo opens straight away and still works with no signal. It never leaves this device, is not shared with anyone, and only opens after \(model.biometricCapability.name). Turning this off deletes the copy now.")
                } else {
                    Text("Turn on \(model.biometricCapability.name) first. Without it there would be nothing guarding the saved copy.")
                }
            }

            // TOTP Section
            Section {
                if let secret = totpSecret {
                    TOTPCodeView(secret: secret)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    Button(role: .destructive) {
                        showTOTPDeleteConfirmation = true
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemImage: "trash.fill", tint: .red)
                            Text("Remove Built-in Authenticator")
                                .fontWeight(.bold)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Button {
                        showTOTPSetup = true
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemImage: "shield.checkered", tint: Neo.live)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Set Up Built-in Authenticator")
                                    .foregroundStyle(.primary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Built-in Authenticator")
            } footer: {
                if totpSecret != nil {
                    Text("This 6-digit code refreshes every 30 seconds and can be used for OmniVox verification. It's linked to your current student ID.")
                } else {
                    Text("Generate verification codes directly in Neo without needing a separate authenticator app. This will register Neo as an authentication application with OmniVox.")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle("App Settings")
        .sheet(isPresented: $showTOTPSetup) {
            loadTOTPSecret()
        } content: {
            TOTPGuidedSetupView(model: model)
        }
        .task {
            loadTOTPSecret()
        }
        .alert("Remove Built-in Authenticator?", isPresented: $showTOTPDeleteConfirmation) {
            Button("Remove", role: .destructive) {
                deleteTOTP()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove Neo as an authentication application from your OmniVox account. You'll need to set up another verification method.")
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { language.selection },
            set: { newValue in
                language.select(newValue)
                // Applied in full, here and now: the app re-renders from the
                // new locale and the portal is read again in the new language.
                // Nothing is left for the student to do — an app cannot relaunch
                // itself, so anything it cannot finish would be their problem
                // to finish.
                model.reloadPortalForLanguageChange()
            }
        )
    }

    private var biometricLockBinding: Binding<Bool> {
        Binding(
            get: { pendingLockValue ?? model.biometricLockEnabled },
            set: { updateBiometricLock(to: $0) }
        )
    }

    private func updateBiometricLock(to enabled: Bool) {
        pendingLockValue = enabled
        isUpdatingLock = true
        authenticationFailed = false

        Task {
            let updated = await model.setBiometricLockEnabled(enabled)
            pendingLockValue = nil
            isUpdatingLock = false
            authenticationFailed = !updated
        }
    }

    private func loadTOTPSecret() {
        totpSecret = model.getTOTPSecret()
    }

    private func deleteTOTP() {
        guard let profileID = profileStore.activeProfileID else { return }
        let vault = TOTPVault(profileID: profileID)
        vault.delete()
        totpSecret = nil
    }
}

private struct SettingsRowLabel: View {
    /// A key rather than a String, so `Text` localizes it instead of printing
    /// it verbatim.
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    var isDestructive = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemImage: systemImage, tint: tint)

            Text(title)
                .fontWeight(isDestructive ? .bold : .regular)
                .foregroundStyle(isDestructive ? Color.red : Color.primary)
        }
        .contentShape(Rectangle())
    }
}

/// The tinted glyph that leads every settings row.
///
/// Shared with the other settings screens rather than private to this one, so
/// a row added elsewhere lines up with the rows here.
struct SettingsIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}
