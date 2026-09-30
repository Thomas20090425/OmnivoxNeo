import Foundation

/// Why the app is running on what it already had.
///
/// Both states look almost the same from the inside — the schedule, Léa and
/// MIO are whatever was last saved to this device, and anything that would
/// need the college is off — but they mean opposite things and must never be
/// confused for one another.
///
/// `offline` is nobody's fault and costs nothing: come back into range and it
/// clears itself. It is **not** a sign-out, and the next launch still opens
/// with a face scan.
///
/// `mustSignInAgain` is the portal refusing the saved session — the password
/// changed, the cookies died, or the college has something to say first. That
/// one ends in a real sign-in, on a clock, and the clock survives the app
/// being killed.
enum SessionLimitation: Equatable, Sendable {
    case offline
    case mustSignInAgain(deadline: Date)

    var deadline: Date? {
        if case .mustSignInAgain(let deadline) = self { return deadline }
        return nil
    }

    /// Whether anything that talks to the college should be off.
    ///
    /// True for both: a countdown means the session is already being refused,
    /// so a refresh would fail exactly as the one that started the countdown
    /// did.
    var blocksTheCollege: Bool { true }
}

extension SessionLimitation {
    /// How long a student gets before the app takes them to a real sign-in.
    ///
    /// Long enough to finish reading the message that is open; short enough
    /// that the app is not pretending to be signed in for the rest of the day.
    static let graceSeconds: TimeInterval = 60
}
