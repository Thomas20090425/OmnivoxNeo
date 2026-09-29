import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The accent colours a student can pick from.
///
/// A curated set rather than a colour wheel: every value here has been chosen
/// to stay legible as white-on-colour in a filled button and as colour-on-white
/// in a link, in both light and dark appearance. An arbitrary picker cannot
/// promise that.
///
/// Shared with the widget so a Home Screen tile matches the app the student
/// opens from it.
public enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    /// The default. Its raw value still spells the school this app was
    /// first written for, and has to: it is what is already written into
    /// every existing student's preferences, and renaming it would quietly
    /// reset their chosen colour. Nothing they see says it.
    case blue = "dawsonBlue"
    case indigo
    case violet
    case magenta
    case crimson
    case orange
    case forest
    case teal
    case graphite

    public var id: String { rawValue }

    public static func named(_ id: String?) -> AccentChoice {
        guard let id, let choice = AccentChoice(rawValue: id) else { return .blue }
        return choice
    }

    public var title: String {
        switch self {
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .violet: "Violet"
        case .magenta: "Magenta"
        case .crimson: "Crimson"
        case .orange: "Orange"
        case .forest: "Forest"
        case .teal: "Teal"
        case .graphite: "Graphite"
        }
    }

    /// Light and dark variants. The dark one is always the lighter of the two:
    /// a colour that reads well on white is too dark to read on black.
    public var color: Color {
        switch self {
        case .blue:       Self.adaptive(light: (0.039, 0.361, 0.722), dark: (0.380, 0.710, 1.000))
        case .indigo:     Self.adaptive(light: (0.235, 0.271, 0.671), dark: (0.557, 0.592, 0.976))
        case .violet:     Self.adaptive(light: (0.408, 0.247, 0.686), dark: (0.706, 0.588, 0.988))
        case .magenta:    Self.adaptive(light: (0.663, 0.161, 0.463), dark: (0.949, 0.522, 0.769))
        case .crimson:    Self.adaptive(light: (0.694, 0.137, 0.180), dark: (1.000, 0.514, 0.506))
        case .orange:     Self.adaptive(light: (0.639, 0.333, 0.039), dark: (1.000, 0.698, 0.310))
        case .forest:     Self.adaptive(light: (0.086, 0.400, 0.216), dark: (0.416, 0.816, 0.549))
        case .teal:       Self.adaptive(light: (0.020, 0.400, 0.435), dark: (0.361, 0.788, 0.824))
        case .graphite:   Self.adaptive(light: (0.255, 0.278, 0.310), dark: (0.706, 0.741, 0.780))
        }
    }

    static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
        })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
        #else
        Color(red: light.0, green: light.1, blue: light.2)
        #endif
    }
}
