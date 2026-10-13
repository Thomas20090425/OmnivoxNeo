//
//  ContentView.swift
//  OmnivoxNeo
//
//  Created by Thomas on 2026-09-03.
//

import Combine
import SwiftUI

/// Owns which profile is active and rebuilds the whole session when it changes.
///
/// An `AppModel` is bound to one profile for its lifetime — its WebView data
/// store, Keychain items and caches are all keyed by that profile's UUID — so
/// switching accounts means building a new one rather than mutating the old.
/// The `.id(...)` below is what forces that: SwiftUI tears the subtree down and
/// stands a fresh `AppModel` up, leaving the previous profile's session intact
/// on disk for when the user switches back.
struct ContentView: View {
    @StateObject private var profileStore = PortalProfileStore.shared
    @ObservedObject private var language = AppLanguageStore.shared

    var body: some View {
        Group {
            // Keyed on the session, not just the profile: signing out in place
            // keeps the same profile but still needs a fresh session, and the
            // token in the identity is what makes that rebuild happen.
            if let session = profileStore.sessionIdentity {
                PortalSessionView(profileID: session.profileID)
                    .id(session)
            } else {
                LaunchingView()
            }
        }
        .environmentObject(profileStore)
        // The whole app's language, in one line. SwiftUI resolves every
        // `Text("…")` against this locale, so switching it re-renders the app
        // in the new language immediately — no relaunch, and no writing to
        // `AppleLanguages` behind iOS's back.
        .environment(\.locale, language.locale)
        // Account operations survive the session rebuild that carries them out,
        // so the message they leave behind is shown here rather than by the
        // model that no longer exists.
        .alert(
            "Account Already Added",
            isPresented: Binding(
                get: { profileStore.accountNotice != nil },
                set: { if !$0 { profileStore.accountNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { profileStore.accountNotice = nil }
        } message: {
            Text(profileStore.accountNotice ?? "")
        }
        .task {
            _ = profileStore.resolveActiveProfile(
                defaultInstitutionID: SchoolCatalog.default.id
            )
        }
    }
}

/// One profile's live session.
private struct PortalSessionView: View {
    @StateObject private var model: AppModel
    @ObservedObject private var personalization = Personalization.shared
    @Environment(\.scenePhase) private var scenePhase

    init(profileID: UUID) {
        let institution = PortalProfileStore.shared.profiles
            .first { $0.id == profileID }?
            .institution ?? .dawson

        _model = StateObject(
            wrappedValue: AppModel(institution: institution, profileID: profileID)
        )

        // Colour and wallpaper belong to the account, so they are loaded before
        // the first frame of that account's session is drawn.
        Personalization.shared.activate(profileID: profileID)
    }

    /// Used by previews and tests that supply their own model.
    init(model: AppModel) {
        _model = StateObject(wrappedValue: model)
    }

    /// Whether the app has been open this launch.
    ///
    /// What it buys is where you come back to. The lock used to replace the
    /// app rather than cover it, so every unlock built a brand new `HomeView`
    /// — which meant Home, every time, and a fresh read of the whole term to
    /// get there, however briefly you had been away. Kept underneath instead,
    /// the app you come back to is the one you left, on the tab you left it on,
    /// with what it had already read still in hand.
    ///
    /// It is `@State` on purpose: a launch from cold has no history to return
    /// to, so that one does open on Home.
    @State private var hasOpened = false

    /// Whether the app may stay loaded behind whatever is on top.
    ///
    /// Only behind the lock. Behind **sign-in** it must not, and that
    /// distinction is not cosmetic: `HomeView` drives three web views of its
    /// own — the timetable, Léa and MIO — against the same OmniVox session
    /// that the sign-in flow is in the middle of using. Left mounted during a
    /// verification step, those reads land on the portal while it is partway
    /// through a two-factor challenge, the sign-in flow finds a page it does
    /// not recognise, and it gives up with "this step could not be presented
    /// safely" — no code field, no autofill banner, and a loop that only a
    /// reinstall escapes. Keeping the session warm is worth something; it is
    /// not worth standing on the sign-in.
    private var keepsAppLoaded: Bool {
        guard hasOpened else { return false }
        switch model.screen {
        case .schedule, .locked: return true
        // The interception sits with the rest of them for the same reason: it
        // drives the portal session directly, and Home's three web views would
        // be reading the same session out from under it.
        case .launching, .login, .verification, .securitySetupGuidance, .securitySetup,
             .schoolInterception:
            return false
        }
    }

    var body: some View {
        ZStack {
            NeoBackground()

            if keepsAppLoaded {
                HomeView(model: model)
            }

            if model.screen != .schedule {
                ZStack {
                    NeoBackground()
                    switch model.screen {
                    case .launching:
                        LaunchingView()
                    case .locked:
                        LockedView(model: model)
                    case .login:
                        LoginView(model: model)
                    case .verification:
                        VerificationView(model: model)
                    case .securitySetupGuidance:
                        SecuritySetupGuidanceView(model: model)
                    case .securitySetup:
                        SecuritySetupView(model: model)
                    case .schoolInterception:
                        SchoolInterceptionView(model: model)
                    case .schedule:
                        EmptyView()
                    }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: model.screen, initial: true) { _, screen in
            if screen == .schedule { hasOpened = true }
        }
        .tint(Neo.accent)
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 720)
        #endif
        .task {
            if scenePhase == .active {
                await model.applicationBecameActive()
            }
        }
        .onDisappear {
            // This profile's session is being torn down for another account.
            model.endSession()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                model.applicationDidEnterBackground()
            case .active:
                Task { await model.applicationBecameActive() }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

#Preview {
    ContentView()
}
