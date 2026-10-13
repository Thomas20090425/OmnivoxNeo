import Foundation
import WebKit

/// Removes what belongs to one profile.
///
/// Two depths, and the difference is the whole point of the profile system:
///
/// - `signOut` ends the session. The portal cookies, the saved password and the
///   cached schedule go; the student ID, the display name and the enrolled
///   authenticator stay. Signing back in needs the password only, and the saved
///   authenticator answers the verification code automatically.
/// - `erase` removes the account from the device entirely, authenticator
///   included, so the next sign-in starts from nothing.
@MainActor
enum ProfileEraser {
    static func signOut(_ profile: PortalProfile) async {
        let institutionHost = profile.institution.host

        _ = PortalCredentialVault(profileID: profile.id).clear()
        _ = PortalTrustedStateVault(
            profileID: profile.id,
            institutionHost: institutionHost,
            portalDomainSuffix: profile.institution.conventions.portalDomainSuffix,
            sessionOnlyCookieNames: profile.institution.conventions.sessionOnlyCookieNames,
            sessionOnlyCookiePrefixes: profile.institution.conventions.sessionOnlyCookiePrefixes
        ).clear()
        ScheduleCache(profileID: profile.id).clear()

        await clearWebsiteData(for: profile.id)
        clearPreferences(for: profile.id, includingAuthenticatorHints: false)

        // A Home Screen widget must not keep showing the schedule — or the
        // wallpaper — of someone who just signed out. The next session
        // republishes its own.
        SharedSchedule.clear()
        SharedAppearance.clear()
        WidgetRefresh.reload()

        // The mirrored calendar describes a session that no longer exists, so
        // it goes with the session. The *subscription* is kept: signing back in
        // should restore the calendar the student already asked for rather than
        // make them ask again.
        try? CalendarSyncService.removeEverything(profileID: profile.id)
    }

    static func erase(_ profile: PortalProfile) async {
        await signOut(profile)

        // The authenticator only dies here. A sign-out that took it with it
        // would make "log back in" mean "enrol a new authenticator", which is
        // exactly the friction the saved secret exists to remove.
        TOTPVault(profileID: profile.id).delete()
        CalendarSubscription(profileID: profile.id).clear()
        AgendaReadState(profileID: profile.id).clear()
        clearPreferences(for: profile.id, includingAuthenticatorHints: true)
        removeProfileDirectory(for: profile.id)

        // The last student ID is kept across a sign-out on purpose, so signing
        // back in only needs a password. Removing the account is the other
        // thing entirely — it says start from nothing — and a student number
        // still sitting in the sign-in field afterwards makes a liar of that.
        // Only cleared when it belonged to the account being removed, so
        // deleting one of several accounts does not empty the field for the
        // one that is still here.
        if UserDefaults.standard.string(forKey: retainedStudentIDKey) == profile.studentID {
            UserDefaults.standard.removeObject(forKey: retainedStudentIDKey)
        }
    }

    /// Mirrors `AppModel.studentIDPreferenceKey`, which is private to it.
    private static let retainedStudentIDKey = "login.last-student-id"

    // MARK: - Storage

    private static func clearWebsiteData(for profileID: UUID) async {
        guard #available(iOS 17.0, macOS 14.0, *) else { return }
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    /// Per-profile `UserDefaults` keys. These are written with a
    /// `<uuid>.`-prefixed or `<suffix>.<uuid>` shape depending on the call site,
    /// so both are swept.
    private static func clearPreferences(
        for profileID: UUID,
        includingAuthenticatorHints: Bool
    ) {
        let defaults = UserDefaults.standard
        let id = profileID.uuidString

        // Face ID and the security walkthrough go with the saved password. A
        // signed-out account has nothing left behind Face ID to unlock, so
        // leaving the flag on would prompt for a scan that cannot succeed.
        var suffixed = [
            "totp.prompt-shown",
            "security.biometric-lock-enabled",
            "security.initial-setup-complete",
            "security-guidance-shown"
        ]
        if includingAuthenticatorHints {
            suffixed.append("totp.method-reference")
        }
        for key in suffixed {
            defaults.removeObject(forKey: "\(key).\(id)")
        }

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("\(id).") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func removeProfileDirectory(for profileID: UUID) {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base
            .appendingPathComponent("profiles")
            .appendingPathComponent(profileID.uuidString)
        try? FileManager.default.removeItem(at: directory)
    }
}
