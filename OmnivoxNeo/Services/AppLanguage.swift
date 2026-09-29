import Combine
import Foundation
import SwiftUI

/// The language the app draws itself in.
///
/// Quebec requires French, so French is a first-class localization rather than
/// a community translation bolted on later. `system` is the default and the
/// right answer for almost everyone: it follows the phone, which is what a
/// student has already told iOS they want.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case french = "fr"

    var id: String { rawValue }

    /// Written in the language it selects, the way iOS lists languages — a
    /// student looking for French is looking for the word "Français".
    var nativeName: String {
        switch self {
        case .system: String(localized: "Automatic")
        case .english: "English"
        case .french: "Français"
        }
    }

    /// The locale to resolve strings against, or nil to follow the device.
    var explicitLocale: Locale? {
        switch self {
        case .system: nil
        case .english, .french: Locale(identifier: rawValue)
        }
    }
}

/// Which language the app is using, and the machinery to switch it live.
///
/// SwiftUI resolves `Text("…")` against the environment's locale, so pushing a
/// locale in at the root re-renders the whole app in that language immediately
/// — no relaunch, and no writing to `AppleLanguages` behind iOS's back.
///
/// Strings built outside a view have no environment to read, so they go through
/// `Loc` instead, which looks them up in the matching `.lproj`. Both paths fall
/// back to the English source text when a translation is missing, so a
/// half-translated build is merely half-translated rather than broken.
@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()

    private static let storageKey = "app.language"
    /// The preference WebKit and the bundle loader read at process start.
    private static let systemLanguagesKey = "AppleLanguages"

    private let defaults: UserDefaults

    private(set) var selection: AppLanguage {
        didSet { rebuildResolvedValues() }
    }

    /// The locale to hand to SwiftUI's environment.
    private(set) var locale: Locale = .current

    /// The bundle `Loc` reads from.
    private(set) var bundle: Bundle = .main

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = AppLanguage(rawValue: defaults.string(forKey: Self.storageKey) ?? "")
            ?? .system
        rebuildResolvedValues()
    }

    func select(_ language: AppLanguage) {
        guard language != selection else { return }
        objectWillChange.send()
        selection = language
        defaults.set(language.rawValue, forKey: Self.storageKey)

        // Also written where the system looks, so that after a relaunch the
        // WebView asks the portal for this language too. Removing the key hands
        // the choice back to the phone.
        if let code = language.explicitLocale?.language.languageCode?.identifier {
            defaults.set([code], forKey: Self.systemLanguagesKey)
        } else {
            defaults.removeObject(forKey: Self.systemLanguagesKey)
        }
    }

    /// The language actually in effect, including what `system` resolved to.
    var effectiveLanguageCode: String {
        locale.language.languageCode?.identifier ?? "en"
    }

    /// The language to ask the portal for, or nil to let it decide.
    ///
    /// Read fresh on every request rather than frozen at launch, which is what
    /// lets a language change take effect without reopening the app: the next
    /// portal load simply asks for the new one.
    var portalLanguageCode: String? {
        selection.explicitLocale?.language.languageCode?.identifier
    }

    /// `Accept-Language` for requests the app builds itself.
    ///
    /// Set per request, so it does not depend on the process-wide preference
    /// WebKit only reads at launch. Only sent when a language was explicitly
    /// chosen; on `system` WebKit's own header already says the right thing.
    var acceptLanguageHeader: String? {
        guard let code = selection.explicitLocale?.language.languageCode?.identifier else {
            return nil
        }
        let regional = Locale.current.region.map { "\(code)-\($0.identifier)" } ?? code
        let fallback = code == "fr" ? "en" : "fr"
        return "\(regional),\(code);q=0.9,\(fallback);q=0.8"
    }

    private func rebuildResolvedValues() {
        if let explicit = selection.explicitLocale {
            locale = explicit
            bundle = Self.localizedBundle(for: explicit) ?? .main
        } else {
            locale = .autoupdatingCurrent
            bundle = .main
        }
    }

    /// The `.lproj` for a language, falling back to the main bundle when the
    /// app has not been localized into it yet.
    private static func localizedBundle(for locale: Locale) -> Bundle? {
        guard let code = locale.language.languageCode?.identifier else { return nil }
        guard
            let path = Bundle.main.path(forResource: code, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return nil
        }
        return bundle
    }
}

/// Localized strings for code that cannot use `Text`.
///
/// Views should use `Text("…")` directly — it is extracted automatically and
/// follows the environment. This exists for the model layer, which produces
/// messages long before any view sees them.
///
/// The key *is* the English text, so a missing translation returns readable
/// English rather than a dangling identifier.
@MainActor
enum Loc {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: AppLanguageStore.shared.bundle, comment: "")
    }

    /// `key` is a `String(format:)` template, e.g. `"%@ could not be reached."`.
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: NSLocalizedString(key, bundle: AppLanguageStore.shared.bundle, comment: ""),
            locale: AppLanguageStore.shared.locale,
            arguments: arguments
        )
    }
}
