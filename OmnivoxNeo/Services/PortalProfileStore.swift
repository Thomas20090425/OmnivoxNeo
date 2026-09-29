import Foundation
import Combine

/// Manages all signed-in profiles. One profile per account, keyed by a stable
/// UUID that never changes, so storage scoping works before the student ID is known.
@MainActor
class PortalProfileStore: ObservableObject {
    static let shared = PortalProfileStore()

    @Published private(set) var profiles: [PortalProfile] = []
    @Published private(set) var activeProfileID: UUID?
    /// A one-shot message to show after an account operation that crossed a
    /// session rebuild, where the model that produced it no longer exists.
    @Published var accountNotice: String?

    /// True only while the user is deliberately adding an account.
    ///
    /// Signing out the last account also lands on a sign-in screen, but it is
    /// not the same screen: it prefills the student ID and offers no way to
    /// "cancel back" to an account that no longer exists. Inferring the
    /// difference from how many profiles happen to exist got that wrong, so it
    /// is stated outright.
    @Published private(set) var isAddingAccount = false

    /// Changes whenever the live session must be rebuilt, including when the
    /// profile itself is unchanged — signing out in place, for example.
    @Published private(set) var sessionToken = UUID()

    struct SessionIdentity: Hashable {
        let profileID: UUID
        let token: UUID
    }

    var sessionIdentity: SessionIdentity? {
        activeProfileID.map { SessionIdentity(profileID: $0, token: sessionToken) }
    }

    private let storageKey = "com.tjokas.OmnivoxNeo.profiles"

    private init() {
        load()
    }

    var activeProfile: PortalProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    // MARK: - Lifecycle

    /// Create a new profile for the given institution. Returns the ID.
    func createProfile(institutionID: String) -> UUID {
        let profile = PortalProfile(institutionID: institutionID)
        profiles.append(profile)
        activeProfileID = profile.id
        save()
        return profile.id
    }

    /// Bind the active profile to a student ID once the portal confirms it.
    func bindActiveProfile(studentID: String, displayName: String?) {
        guard let id = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == id })
        else { return }

        profiles[index].studentID = studentID
        profiles[index].displayName = displayName
        profiles[index].lastUsedAt = Date()
        save()
    }

    /// Update the display name for the active profile.
    func updateActiveProfileName(_ displayName: String?) {
        guard let id = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == id })
        else { return }

        profiles[index].displayName = displayName
        save()
    }

    /// Touch the active profile's `lastUsedAt`.
    func touchActiveProfile() {
        guard let id = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == id })
        else { return }

        profiles[index].lastUsedAt = Date()
        save()
    }

    /// Switch to a different profile by ID. Returns the profile if it exists.
    ///
    /// Switching is not signing out: the profile being left keeps its session,
    /// cookies and saved password, so switching back costs nothing.
    @discardableResult
    func switchTo(_ profileID: UUID) -> PortalProfile? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            return nil
        }
        activeProfileID = profileID
        touchActiveProfile()
        return profile
    }

    /// Mark a profile signed out while keeping it on the device. Its student ID,
    /// name and enrolled authenticator survive; only the session does not.
    func markSignedOut(_ profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].isSignedOut = true
        save()
    }

    /// Called once the portal confirms a session is live again.
    func markSignedIn(_ profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].isSignedOut
        else { return }
        profiles[index].isSignedOut = false
        save()
    }

    /// Remove the profile record. Storage is erased separately by `ProfileEraser`
    /// so this stays a pure bookkeeping operation.
    func forgetProfile(_ profileID: UUID) {
        profiles.removeAll { $0.id == profileID }
        if activeProfileID == profileID {
            activeProfileID = profiles.max(by: { $0.lastUsedAt < $1.lastUsedAt })?.id
        }
        save()
    }

    /// The profile to show when the app launches, creating one if the device
    /// has none yet.
    func resolveActiveProfile(defaultInstitutionID: String) -> UUID {
        if let activeProfileID, profiles.contains(where: { $0.id == activeProfileID }) {
            return activeProfileID
        }
        if let mostRecent = profiles.max(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            activeProfileID = mostRecent.id
            save()
            return mostRecent.id
        }
        return createProfile(institutionID: defaultInstitutionID)
    }

    /// A brand-new, never-bound profile already waiting at the same
    /// institution, so "Add Account" cannot pile up empty entries — while
    /// still letting a different school start its own.
    func unboundProfile(at institutionID: String) -> PortalProfile? {
        profiles.first { !$0.isBound && $0.institutionID == institutionID }
    }

    /// A different profile that already owns this identity. One student at one
    /// institution is one account: a second copy would split their schedule,
    /// trusted-device state and authenticator across two entries that can never
    /// agree with each other.
    func existingProfile(
        institutionID: String,
        studentID: String,
        excluding profileID: UUID?
    ) -> PortalProfile? {
        profiles.first {
            $0.id != profileID
                && $0.institutionID == institutionID
                && $0.studentID == studentID
                && $0.isBound
        }
    }

    /// Begin a deliberate add-account flow, reusing a placeholder if one is
    /// already waiting at that school.
    func beginAddingAccount(at institutionID: String) {
        isAddingAccount = true
        if let waiting = unboundProfile(at: institutionID) {
            switchTo(waiting.id)
        } else {
            _ = createProfile(institutionID: institutionID)
        }
    }

    func endAddingAccount() {
        isAddingAccount = false
    }

    /// Where the app lands after an account is logged out or deleted.
    ///
    /// If another account is still on the device we switch to it. If that was
    /// the last one, we land on the plain sign-in screen — never the
    /// add-account screen, because there is nothing to go back to.
    func finishAccountRemoval(removed: PortalProfile, wasDeleted: Bool) {
        isAddingAccount = false

        // Prefer an account that is still signed in: landing on another
        // account's login screen is barely better than landing on your own.
        let remaining = profiles.filter { $0.id != removed.id }
        if let next = remaining.first(where: { !$0.isSignedOut && $0.isBound })
            ?? remaining.max(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            switchTo(next.id)
            return
        }

        if wasDeleted {
            // Nothing of the old account survives, so start a clean one.
            _ = createProfile(institutionID: removed.institutionID)
        } else {
            // The account stays, signed out. Same profile, new session — so the
            // token is what forces the rebuild onto the sign-in screen.
            activeProfileID = removed.id
        }
        sessionToken = UUID()
        save()
    }

    /// Folds a half-finished "Add Account" attempt into the account it turned
    /// out to duplicate, and leaves a message for the next screen to show.
    func mergeIntoExisting(placeholder: UUID?, existing: PortalProfile, message: String) {
        if let placeholder, placeholder != existing.id {
            profiles.removeAll { $0.id == placeholder }
        }
        accountNotice = message
        activeProfileID = existing.id
        touchActiveProfile()
        save()
    }

    /// Find a profile by institution + student ID. Returns nil if not found.
    func findProfile(institutionID: String, studentID: String) -> PortalProfile? {
        profiles.first {
            $0.institutionID == institutionID && $0.studentID == studentID
        }
    }

    // MARK: - Storage

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PortalProfile].self, from: data)
        else { return }

        profiles = decoded
        // Active profile is the most recently used
        activeProfileID = profiles.max(by: { $0.lastUsedAt < $1.lastUsedAt })?.id
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
