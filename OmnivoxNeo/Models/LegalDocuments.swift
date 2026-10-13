import Combine
import Foundation

/// Where this app's own agreements live, and which revision of them a student
/// has agreed to.
///
/// The app shows both documents from copies carried in its own bundle, so they
/// open with no signal and cannot drift from what was agreed to. The published
/// addresses below are not used to display anything — they are the canonical
/// record of where the same text lives on the web, for the App Store listing
/// and for anyone who wants to read it outside the app.
enum LegalDocuments {
    /// Bumped whenever the agreements change in a way a student should see.
    ///
    /// Acceptance is recorded against this, so a revision asks again rather
    /// than quietly treating an old yes as covering new terms. That is the
    /// difference between a consent record that means something and one that
    /// only looks like it does.
    /// Moved for the feedback feature: it is the first thing in this app that
    /// sends anything to a party other than the student's own college, and the
    /// agreements promised in writing that such a feature would be described
    /// and re-accepted before it shipped rather than announced afterwards.
    static let currentVersion = "2026-10-13b"

    /// This app's own End User Licence Agreement, as published.
    ///
    /// - Note: `docs/` is in the path because GitHub Pages for this repository
    ///   serves from the branch root rather than from the `docs` folder. These
    ///   addresses are the ones that actually answer; they were checked rather
    ///   than assumed, since a link that 404s in a submission is a rejection.
    static let eulaURL = URL(
        string: "https://thomas20090425.github.io/OmnivoxNeo/docs/terms.html"
    )
    /// This app's own privacy policy, as published.
    static let privacyURL = URL(
        string: "https://thomas20090425.github.io/OmnivoxNeo/docs/privacy.html"
    )

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
    private static let dateKey = "legal.accepted-date"

    private let defaults: UserDefaults

    @Published private(set) var acceptedVersion: String?
    /// When it was accepted.
    ///
    /// Kept because in Quebec the burden of showing that someone knew about a
    /// limitation when the contract was formed falls on the party relying on
    /// it, not on the person who agreed. A record nobody can see proves
    /// nothing to the person it is about, so this one is shown back to them.
    @Published private(set) var acceptedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        acceptedVersion = defaults.string(forKey: Self.key)
        acceptedAt = defaults.object(forKey: Self.dateKey) as? Date
    }

    /// Whether the revision now in force has been accepted.
    var hasAcceptedCurrent: Bool {
        acceptedVersion == LegalDocuments.currentVersion
    }

    func accept() {
        let now = Date()
        acceptedVersion = LegalDocuments.currentVersion
        acceptedAt = now
        defaults.set(LegalDocuments.currentVersion, forKey: Self.key)
        defaults.set(now, forKey: Self.dateKey)
    }

    func withdraw() {
        acceptedVersion = nil
        acceptedAt = nil
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.dateKey)
    }
}
