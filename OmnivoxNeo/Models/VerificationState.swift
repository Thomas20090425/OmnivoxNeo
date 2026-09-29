import Foundation

struct VerificationMethodOption: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case mobile
        case email
        case authenticator
        case other

        var systemImage: String {
            switch self {
            case .mobile: "iphone"
            case .email: "envelope.fill"
            case .authenticator: "lock.shield.fill"
            case .other: "checkmark.shield.fill"
            }
        }
    }

    let id: Int
    let kind: Kind
    let title: String
    let detail: String
    /// Portal-assigned identifier taken from the method card's href, when the
    /// card exposes one. Lets us click and recognize a method without relying
    /// on its position in the list.
    var reference: String?
}

struct VerificationState: Equatable, Sendable {
    enum Mode: Sendable {
        case loading
        case code
        case methods
        case unavailable
        /// The college is holding sign-in up over something only it can settle
        /// — an ID photo it wants, a form, an agreement.
        ///
        /// It arrives here as a page the app cannot classify, and for a long
        /// time that is all it was: a dead end reading "this step could not be
        /// presented safely", with nothing behind it but a loop. It was never
        /// a broken step. OmniVox is refusing to go any further until the
        /// student does something on the college's own site, and the only
        /// useful thing this app can do is say so, take them there, and let
        /// them come back and carry on.
        case schoolActionRequired
    }

    var mode: Mode
    var title: String
    var instruction: String
    var destination: String?
    var methods: [VerificationMethodOption]
    var canRequestNewCode: Bool
    var canChooseAnotherMethod: Bool
    var canGoBack: Bool
    var trustedDeviceSelected: Bool
    var errorMessage: String?
    /// Which verification method the code entry page belongs to, when the page
    /// identifies itself. `.other` means the portal gave us nothing to go on,
    /// so the page must not be treated as any particular method.
    var codeMethodKind: VerificationMethodOption.Kind = .other
    /// Portal-assigned identifier of the method this page belongs to, read from
    /// the `/apps/mfa/login/validate-method/<id>` path.
    var methodReference: String?

    /// Computed and main-actor isolated: these two strings are shown to the
    /// student, so they have to be resolved in the language in effect when the
    /// state is created rather than frozen at first use.
    @MainActor
    static var loading: VerificationState {
        VerificationState(
            mode: .loading,
            title: Loc.text("Verify your identity"),
            instruction: Loc.text("Preparing your verification options…"),
            destination: nil,
            methods: [],
            canRequestNewCode: false,
            canChooseAnotherMethod: false,
            canGoBack: false,
            trustedDeviceSelected: false,
            errorMessage: nil
        )
    }
}
