import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The app's whole visual vocabulary.
///
/// Colour is defined by *role*, and every role but one resolves to a system
/// colour, so light, dark, increased contrast and larger text are handled by
/// the platform rather than re-specified here. Three meanings, and only three:
///
/// - **accent** — you can act on this
/// - **live** — this is happening right now
/// - **red** — this destroys something, or it failed
///
/// Everything else is greyscale: `.primary`, `.secondary`, `.tertiary`.
enum Neo {
    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        var alpha = 1.0
    }

    /// The accent the student picked; blue by default.
    ///
    /// Reading from the personalization store rather than being a constant is
    /// what lets the whole app re-tint at once; views re-render because they
    /// observe that store, and every `Neo.accent` they draw then resolves to
    /// the new value.
    static var accent: Color {
        Personalization.shared.accent.color
    }

    /// Builds a light/dark pair from raw sRGB components. Exposed so accent
    /// choices can be declared next to each other instead of here.
    static func adaptiveColor(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        adaptive(
            light: RGBA(red: light.0, green: light.1, blue: light.2),
            dark: RGBA(red: dark.0, green: dark.1, blue: dark.2)
        )
    }

    /// Reserved for "in progress right now" — the running class and nothing
    /// else. Never used for a control, so its meaning stays unambiguous.
    static let live = Color.green

    /// The page behind grouped content.
    static var canvas: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// A raised content group sitting on `canvas`.
    static var surface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// An inset control inside a `surface` — a text field, a well.
    static var inset: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemGroupedBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    static var separator: Color {
        #if os(iOS)
        Color(uiColor: .separator)
        #else
        Color(nsColor: .separatorColor)
        #endif
    }

    /// Corner radius of a grouped content block, matching an inset-grouped list.
    static let cardRadius: CGFloat = 12
    /// Corner radius of a control inside a block.
    static let controlRadius: CGFloat = 10

    private static func adaptive(light: RGBA, dark: RGBA) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat(value.red),
                green: CGFloat(value.green),
                blue: CGFloat(value.blue),
                alpha: CGFloat(value.alpha)
            )
        })
        #elseif os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat(value.red),
                green: CGFloat(value.green),
                blue: CGFloat(value.blue),
                alpha: CGFloat(value.alpha)
            )
        })
        #endif
    }
}

/// The app's page background, and the only place a wallpaper is drawn.
///
/// Content stays on opaque cards on top of this, so a photo never has to be
/// legible enough to read text through — it shows at the margins and behind the
/// grouped blocks, the way a Home Screen wallpaper sits behind widgets.
struct NeoBackground: View {
    @ObservedObject private var personalization = Personalization.shared

    var body: some View {
        Group {
            switch personalization.wallpaper {
            case .none:
                Neo.canvas

            case .builtIn(let id):
                if let wallpaper = BuiltInWallpaper.named(id) {
                    wallpaper.gradient
                } else {
                    Neo.canvas
                }

            case .photo:
                if let photo = personalization.wallpaperPhoto {
                    photo
                        .resizable()
                        .scaledToFill()
                        // A chosen photo has no contract with the text above it,
                        // so it is pushed back until it cannot compete.
                        .overlay(Neo.canvas.opacity(0.55))
                        .clipped()
                } else {
                    Neo.canvas
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// The app's own icon, rather than a hand-drawn stand-in for it.
///
/// The artwork is the same file the icon set uses, so the splash and sign-in
/// screens can never drift away from what the student taps on the Home Screen.
/// The squircle is applied here because the source art is a plain square.
struct NeoLogo: View {
    var size: CGFloat = 58

    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A grouped block of content on the page background.
///
/// Flat by design: elevation is reserved for surfaces that genuinely float
/// above the content, such as sheets and popovers. Stacking a border and a
/// drop shadow on every block flattens the hierarchy instead of building one.
struct NeoCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Neo.surface, in: RoundedRectangle(cornerRadius: Neo.cardRadius, style: .continuous))
    }
}

struct SessionErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Neo.surface, in: RoundedRectangle(cornerRadius: Neo.cardRadius, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.orange)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                    .padding(.vertical, 10)
            }
            .accessibilityElement(children: .combine)
    }
}

extension View {
    func neoCard() -> some View {
        modifier(NeoCardModifier())
    }

    @ViewBuilder
    func studentIDInputTraits() -> some View {
        #if os(iOS)
        self
            .keyboardType(.numberPad)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .textContentType(.username)
        #endif
    }

    @ViewBuilder
    func omnivoxPasswordInputTraits() -> some View {
        #if os(iOS)
        self
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .textContentType(.password)
        #endif
    }

    /// A field holding a base32 authenticator secret.
    ///
    /// Upper-cased and left uncorrected: the secret is case-insensitive base32,
    /// and autocorrect on a random-looking string is how a working secret
    /// becomes a silently wrong one.
    @ViewBuilder
    func authenticatorSecretInputTraits() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        #else
        self
            .autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func verificationCodeInputTraits() -> some View {
        #if os(iOS)
        self
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .textContentType(.oneTimeCode)
        #endif
    }
}

/// A filled accent button.
///
/// Feedback is instant on press and carries no overshoot: nothing here was
/// thrown or dragged, so a spring bounce would be motion for its own sake.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                Neo.accent.opacity(isEnabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: Neo.controlRadius, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
