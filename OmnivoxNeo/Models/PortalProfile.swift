import Foundation

/// One signed-in account. Identified by a stable `id` that never changes, so a
/// profile can exist before its student ID is known and nothing has to be
/// migrated once the portal tells us who signed in.
///
/// Every per-account store — cookies, schedule cache, saved password, trusted
/// device state, the authenticator secret — is keyed by `id`.
struct PortalProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var institutionID: String
    /// Empty until the portal confirms who signed in.
    var studentID: String
    /// First name scraped from the portal, when known.
    var displayName: String?
    var createdAt: Date
    var lastUsedAt: Date

    /// Optional so profiles written before sign-out was tracked still decode;
    /// a missing value means the profile was last left signed in.
    private var signedOut: Bool?

    init(
        id: UUID = UUID(),
        institutionID: String,
        studentID: String = "",
        displayName: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        isSignedOut: Bool = false
    ) {
        self.id = id
        self.institutionID = institutionID
        self.studentID = studentID
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.signedOut = isSignedOut
    }

    /// Signed out but kept: the portal session and saved password are gone,
    /// while the student ID, name and authenticator secret remain. Signing back
    /// in needs the password only — the saved authenticator answers the code.
    var isSignedOut: Bool {
        get { signedOut ?? false }
        set { signedOut = newValue }
    }

    var institution: Institution {
        Institution.named(institutionID)
    }

    /// True once the portal has confirmed which student this profile belongs to.
    var isBound: Bool {
        studentID.count == 7
    }

    /// The student's full name once the portal has told us, otherwise the best
    /// identifier we have.
    @MainActor
    var accountLabel: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return isBound ? studentID : Loc.text("New Account")
    }

    /// Who this account is, under the name: student ID and school.
    var identityLabel: String {
        guard isBound else { return institution.displayName }
        return "\(studentID) · \(institution.displayName)"
    }

    /// Only set when the account needs attention; nil when it is simply signed
    /// in and fine, so the row does not carry a redundant third line.
    @MainActor
    var statusLabel: String? {
        if isSignedOut { return Loc.text("Logged Out") }
        if !isBound { return Loc.text("Not signed in yet") }
        return nil
    }

    /// Two letters for the avatar: first and last initial, so "Thomas Ma"
    /// becomes "TM". Falls back to the last two digits of the student ID, then
    /// to the school. A profile picture, when there is one, replaces this.
    var monogram: String {
        if let displayName, !displayName.isEmpty {
            let words = displayName
                .split(whereSeparator: { $0.isWhitespace })
                .filter { $0.first?.isLetter == true }

            // First and *last* word, not the first two: a middle name should
            // not push the surname out of the initials.
            let initials = [words.first, words.count > 1 ? words.last : nil]
                .compactMap { $0?.first }
                .map(String.init)
                .joined()

            if !initials.isEmpty { return initials.uppercased() }
        }
        if isBound { return String(studentID.suffix(2)) }
        return String(institution.displayName.prefix(1)).uppercased()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PortalProfile, rhs: PortalProfile) -> Bool {
        lhs.id == rhs.id
    }
}
