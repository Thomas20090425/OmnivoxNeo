import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What sits behind the content.
///
/// Shared with the widget extension so a Home Screen widget can wear the same
/// wallpaper as the app.
public enum WallpaperChoice: Equatable, Sendable {
    /// The system grouped background — no decoration.
    case none
    /// One of the built-in gradients, by id.
    case builtIn(String)
    /// A photo the student chose, stored in their own profile directory.
    case photo

    public var storageValue: String {
        switch self {
        case .none: "none"
        case .builtIn(let id): "builtin:\(id)"
        case .photo: "photo"
        }
    }

    public init(storageValue: String) {
        if storageValue == "photo" {
            self = .photo
        } else if storageValue.hasPrefix("builtin:") {
            self = .builtIn(String(storageValue.dropFirst("builtin:".count)))
        } else {
            self = .none
        }
    }
}

/// A built-in wallpaper, with a real colour for each appearance.
///
/// The dark variants are authored, not derived. Scaling a pale light colour
/// down produces the same near-black for every option, which made all five
/// wallpapers identical — and indistinguishable from having none.
public struct BuiltInWallpaper: Identifiable, Sendable {
    public let id: String
    public let title: String
    private let light: ((Double, Double, Double), (Double, Double, Double))
    private let dark: ((Double, Double, Double), (Double, Double, Double))

    init(
        id: String,
        title: String,
        light: ((Double, Double, Double), (Double, Double, Double)),
        dark: ((Double, Double, Double), (Double, Double, Double))
    ) {
        self.id = id
        self.title = title
        self.light = light
        self.dark = dark
    }

    /// Still restrained — a wallpaper sits under text and cards — but dark mode
    /// keeps enough saturation to be recognisably its own colour.
    public var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Self.adaptive(light: light.0, dark: dark.0),
                Self.adaptive(light: light.1, dark: dark.1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Resolved by the trait environment rather than by reading a colour scheme,
    /// so it works identically in the app and in a widget snapshot.
    private static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        #if canImport(UIKit)
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
        #else
        Color(.sRGB, red: light.0, green: light.1, blue: light.2)
        #endif
    }

    public static let all: [BuiltInWallpaper] = [
        BuiltInWallpaper(
            id: "dawn", title: "Dawn",
            light: ((1.00, 0.93, 0.88), (0.93, 0.94, 0.98)),
            dark:  ((0.20, 0.11, 0.09), (0.09, 0.08, 0.14))
        ),
        BuiltInWallpaper(
            id: "harbour", title: "Harbour",
            light: ((0.87, 0.93, 0.98), (0.93, 0.96, 0.95)),
            dark:  ((0.06, 0.13, 0.22), (0.05, 0.10, 0.13))
        ),
        BuiltInWallpaper(
            id: "meadow", title: "Meadow",
            light: ((0.90, 0.96, 0.90), (0.95, 0.97, 0.93)),
            dark:  ((0.06, 0.16, 0.10), (0.05, 0.11, 0.09))
        ),
        BuiltInWallpaper(
            id: "dusk", title: "Dusk",
            light: ((0.93, 0.91, 0.98), (0.97, 0.92, 0.95)),
            dark:  ((0.15, 0.09, 0.24), (0.19, 0.08, 0.16))
        ),
        BuiltInWallpaper(
            id: "slate", title: "Slate",
            light: ((0.93, 0.94, 0.95), (0.88, 0.90, 0.93)),
            dark:  ((0.11, 0.13, 0.16), (0.07, 0.08, 0.10))
        )
    ]

    public static func named(_ id: String) -> BuiltInWallpaper? {
        all.first { $0.id == id }
    }
}

/// The look the widget should wear: the accent and the wallpaper of whichever
/// account used the app last.
///
/// Kept separate from `SharedSchedule` because the two change on completely
/// different rhythms — a colour changes the instant it is tapped, a schedule
/// only when the portal is re-scraped — and neither should have to wait on the
/// other to reach the Home Screen.
public struct SharedAppearance: Codable, Sendable {
    public static let fileName = "widget-appearance.json"
    public static let photoFileName = "widget-wallpaper.jpg"

    /// Raw value of the student's `AccentChoice`.
    public let accentID: String
    /// `WallpaperChoice.storageValue`.
    public let wallpaperID: String

    public init(accentID: String, wallpaperID: String) {
        self.accentID = accentID
        self.wallpaperID = wallpaperID
    }

    public var wallpaper: WallpaperChoice {
        WallpaperChoice(storageValue: wallpaperID)
    }

    // MARK: - Shared container

    private static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedSchedule.appGroupID)
    }

    public static var fileURL: URL? {
        directory?.appendingPathComponent(fileName)
    }

    /// The wallpaper photo, copied into the App Group because the widget cannot
    /// read the app's own profile directories.
    public static var photoURL: URL? {
        directory?.appendingPathComponent(photoFileName)
    }

    @discardableResult
    public func write() -> Bool {
        guard let url = Self.fileURL else { return false }
        do {
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func load() -> SharedAppearance? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedAppearance.self, from: data)
    }

    /// Goes with the schedule when an account leaves: a signed-out student's
    /// photo has no business staying on the Home Screen.
    public static func clear() {
        for url in [fileURL, photoURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
