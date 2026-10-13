import Combine
import Foundation

/// Where this app's own agreements live, and which revision of them a student
/// has agreed to.
///
/// The addresses are `nil` until the documents are actually published. That is
/// deliberate rather than a placeholder left behind: a link that goes nowhere
/// is worse than a word that is plainly not a link yet, and this way the
/// acceptance step can ship and be tested before the pages exist. Filling in
/// `eulaURL` and `privacyURL` is the whole of turning them on.
enum LegalDocuments {
    /// Bumped whenever the agreements change in a way a student should see.
    ///
    /// Acceptance is recorded against this, so a revision asks again rather
    /// than quietly treating an old yes as covering new terms. That is the
    /// difference between a consent record that means something and one that
    /// only looks like it does.
    static let currentVersion = "2026-10-13"

    /// This app's own End User Licence Agreement. Not published yet.
    static let eulaURL: URL? = nil
    /// This app's own privacy policy. Not published yet.
    static let privacyURL: URL? = nil

    /// The college's own conditions, which keep applying to a student's
    /// account however they reach it — including through this app.
    static let collegeTermsURL = URL(
        string: "https://dawsoncollege.omnivox.ca/intr/Module/Information/Conditions.aspx"
    )
    /// Skytech's privacy policy for the Omnivox platform itself. The student's
    /// actual school record is governed by this, not by anything here.
    static let omnivoxPrivacyURL = URL(string: "https://skytech.com/en/confid-omnivox")
}

/// Remembers that the agreements were accepted, and which revision of them.
///
/// Stored unscoped, in the app's own preferences: this is an agreement between
/// a person and this app, not between an account and a college. Adding a second
/// account does not mean agreeing again, and signing out does not withdraw it.
@MainActor
final class AgreementAcceptance: ObservableObject {
    static let shared = AgreementAcceptance()

    private static let key = "legal.accepted-version"

    private let defaults: UserDefaults

    @Published private(set) var acceptedVersion: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acceptedVersion = defaults.string(forKey: Self.key)
    }

    /// Whether the revision now in force has been accepted.
    var hasAcceptedCurrent: Bool {
        acceptedVersion == LegalDocuments.currentVersion
    }

    func accept() {
        acceptedVersion = LegalDocuments.currentVersion
        defaults.set(LegalDocuments.currentVersion, forKey: Self.key)
    }

    func withdraw() {
        acceptedVersion = nil
        defaults.removeObject(forKey: Self.key)
    }
}
