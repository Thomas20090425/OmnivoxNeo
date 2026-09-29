import Foundation

/// The one sign-in that never reaches OmniVox.
///
/// Typing this pair on the sign-in screen loads the app's fixture tour instead
/// of authenticating: every screen, populated, with no account and no network
/// request. It exists so the app can be handed to somebody who has no Dawson
/// credentials — a reviewer, a classmate at another college, yourself on a
/// phone that is not set up — without the `--demo-*` launch arguments, which
/// need a Mac and a rebuild.
///
/// Deliberately compiled into release builds, which is the whole point: a
/// debug-only demo is one you can only show to people standing next to Xcode.
/// It is not a way into anybody's data — nothing it displays comes from the
/// portal, no request is sent, and no credential is stored — but the pair is
/// readable in the binary, so it is written here, once, under its own name,
/// rather than hidden inline in the sign-in path.
enum DemoAccount {
    static let studentID = "1112027"
    static let password = "11881188"

    /// The name the demo signs in as. The greeting uses the first word, so
    /// this reads naturally on the schedule while the account row still says
    /// plainly that it is a demo.
    static let displayName = "Thomas Demo"

    /// Exact match, both fields. The ID has already been normalized to digits
    /// by the sign-in path; the password is compared as typed, so a stray
    /// space is a failed sign-in rather than a surprise demo.
    static func matches(studentID: String, password: String) -> Bool {
        studentID == Self.studentID && password == Self.password
    }
}
