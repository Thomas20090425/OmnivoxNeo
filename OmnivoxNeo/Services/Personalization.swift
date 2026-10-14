import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// How the grade-progression chart's vertical axis is scaled.
///
/// There is no right answer, which is why it is a choice. Fitting the axis to
/// the data shows the shape of a term — a four-point slide is visible — but it
/// also makes an 89% sitting just above an 82% class average look like a
/// commanding lead. Anchoring at zero is honest about magnitude and flattens
/// every real change into a line near the top. Students want different ones,
/// and both are defensible.
enum GradeChartScale: String, CaseIterable, Identifiable, Sendable {
    /// Zoom to the marks, with a little headroom. The default.
    case dynamic
    /// Always 0–100%.
    case fromZero

    var id: String { rawValue }
}

/// The student's look-and-feel choices, scoped to their own account.
///
/// Per profile, not per device: two students sharing a phone each keep their
/// own colour, the same way they keep their own schedule.
@MainActor
final class Personalization: ObservableObject {
    static let shared = Personalization()

    // Deliberately not @Published. `activate` runs while SwiftUI is building a
    // session's views, and publishing from there is undefined behaviour. Every
    // change that a view needs to see comes from a tap instead, and those send
    // `objectWillChange` themselves.
    private(set) var accent: AccentChoice = .blue
    private(set) var wallpaper: WallpaperChoice = .none
    private(set) var wallpaperPhoto: Image?
    /// How far back the wallpaper is pushed, as a blur radius in points.
    ///
    /// Zero means none, and that is the point of it being a number rather than
    /// a switch: how much blur a photograph needs is a property of the
    /// photograph. A busy canopy needs a lot before text in front of it
    /// settles down; an out-of-focus sky needs none at all. Only the person
    /// looking at it knows which they have.
    private(set) var wallpaperBlur: Double = Personalization.defaultWallpaperBlur

    /// What a photograph starts at.
    ///
    /// Not zero. Most photographs are detailed enough that text sitting
    /// directly on them — the sign-in terms, the footnotes under a list — is
    /// hard to read, so the first thing somebody sees should be the legible
    /// version. Taking it off is one drag away.
    static let defaultWallpaperBlur: Double = 28
    static let maximumWallpaperBlur: Double = 60

    private(set) var gradeChartScale: GradeChartScale = .dynamic

    /// Icons and colours the student has picked for individual courses, keyed
    /// by course code.
    ///
    /// Keyed by code rather than by the course's identity, so a choice survives
    /// a term rollover and reappears if the same course is retaken.
    private(set) var courseAppearances: [String: CourseAppearance] = [:]

    private var profileID: UUID?
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Lifecycle

    /// Point the store at an account. Called when a session starts, including
    /// after a profile switch, so the colour follows the student.
    func activate(profileID: UUID) {
        guard self.profileID != profileID else { return }
        self.profileID = profileID

        accent = AccentChoice(rawValue: defaults.string(forKey: key("accent")) ?? "")
            ?? .blue
        wallpaper = WallpaperChoice(
            storageValue: defaults.string(forKey: key("wallpaper")) ?? "none"
        )
        gradeChartScale = GradeChartScale(rawValue: defaults.string(forKey: key("gradeChartScale")) ?? "")
            ?? .dynamic
        // `object(forKey:)` rather than `double(forKey:)`, which cannot tell
        // "set to zero" from "never set" — and those mean opposite things
        // here: no blur at all, or the default.
        wallpaperBlur = (defaults.object(forKey: key("wallpaperBlur")) as? Double)
            ?? Self.defaultWallpaperBlur
        courseAppearances = (defaults.data(forKey: key("courseAppearances")))
            .flatMap { try? JSONDecoder().decode([String: CourseAppearance].self, from: $0) } ?? [:]
        loadWallpaperPhoto()
        syncToWidgets()
    }

    // MARK: - Editing

    func setAccent(_ choice: AccentChoice) {
        objectWillChange.send()
        accent = choice
        defaults.set(choice.rawValue, forKey: key("accent"))
        syncToWidgets()
    }

    /// How much the wallpaper is blurred, 0 for not at all.
    ///
    /// Not written to the widgets: the Home Screen already has the system's
    /// own wallpaper behind it, and the square crop used there is a backdrop
    /// to two lines of text rather than to a whole app.
    func setWallpaperBlur(_ radius: Double) {
        let clamped = min(max(radius, 0), Self.maximumWallpaperBlur)
        guard clamped != wallpaperBlur else { return }
        objectWillChange.send()
        wallpaperBlur = clamped
        defaults.set(clamped, forKey: key("wallpaperBlur"))
    }

    func setGradeChartScale(_ choice: GradeChartScale) {
        objectWillChange.send()
        gradeChartScale = choice
        defaults.set(choice.rawValue, forKey: key("gradeChartScale"))
    }

    /// What the student picked for one course, if anything.
    func courseAppearance(for code: String) -> CourseAppearance? {
        courseAppearances[Self.courseKey(code)]
    }

    func setCourseAppearance(_ appearance: CourseAppearance, for code: String) {
        let key = Self.courseKey(code)
        guard !key.isEmpty else { return }
        objectWillChange.send()
        if appearance.isEmpty {
            courseAppearances.removeValue(forKey: key)
        } else {
            courseAppearances[key] = appearance
        }
        defaults.set(try? JSONEncoder().encode(courseAppearances), forKey: self.key("courseAppearances"))
    }

    /// Course codes are compared case- and space-insensitively, because Léa and
    /// the timetable do not always agree on either.
    private static func courseKey(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    func setWallpaper(_ choice: WallpaperChoice) {
        objectWillChange.send()
        wallpaper = choice
        defaults.set(choice.storageValue, forKey: key("wallpaper"))
        if choice != .photo {
            wallpaperPhoto = nil
        }
        syncToWidgets()
    }

    /// Store a chosen photo inside the profile's own directory, so deleting the
    /// account takes the wallpaper with it.
    func setWallpaperPhoto(data: Data) -> Bool {
        guard let profileID, let url = photoURL(for: profileID) else { return false }
        #if os(iOS)
        guard let image = UIImage(data: data),
              let jpeg = downscaled(image).jpegData(compressionQuality: 0.85)
        else { return false }
        #else
        let jpeg = data
        #endif

        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            return false
        }

        loadWallpaperPhoto()
        setWallpaper(.photo)
        return true
    }

    func clearWallpaperPhoto() {
        objectWillChange.send()
        if let profileID, let url = photoURL(for: profileID) {
            try? FileManager.default.removeItem(at: url)
        }
        wallpaperPhoto = nil
        if wallpaper == .photo {
            setWallpaper(.none)
        }
        syncToWidgets()
    }

    var hasWallpaperPhoto: Bool {
        wallpaperPhoto != nil
    }

    // MARK: - Widgets

    /// Mirror the look into the App Group so the Home Screen matches the app.
    ///
    /// Separate from the schedule snapshot on purpose: tapping a colour should
    /// reach the widget immediately, not wait for the next portal refresh.
    private func syncToWidgets() {
        SharedAppearance(
            accentID: accent.rawValue,
            wallpaperID: wallpaper.storageValue
        ).write()

        syncWallpaperPhotoToWidgets()
        WidgetRefresh.reload()
    }

    /// Copy the chosen photo into the shared container, or remove the copy when
    /// it is no longer the wallpaper.
    private func syncWallpaperPhotoToWidgets() {
        guard let target = SharedAppearance.photoURL else { return }

        #if os(iOS)
        guard wallpaper == .photo,
              let profileID,
              let source = photoURL(for: profileID),
              let image = UIImage(contentsOfFile: source.path),
              let data = widgetCrop(image).jpegData(compressionQuality: 0.8)
        else {
            try? FileManager.default.removeItem(at: target)
            return
        }
        try? data.write(to: target, options: .atomic)
        #else
        try? FileManager.default.removeItem(at: target)
        #endif
    }

    // MARK: - Storage

    private func key(_ name: String) -> String {
        guard let profileID else { return "personalization.\(name)" }
        return "personalization.\(name).\(profileID.uuidString)"
    }

    private func photoURL(for profileID: UUID) -> URL? {
        ProfileStorage(profileID: profileID).filePath("wallpaper.jpg")
    }

    private func loadWallpaperPhoto() {
        guard let profileID, let url = photoURL(for: profileID),
              FileManager.default.fileExists(atPath: url.path)
        else {
            wallpaperPhoto = nil
            return
        }
        #if os(iOS)
        guard let image = UIImage(contentsOfFile: url.path) else {
            wallpaperPhoto = nil
            return
        }
        wallpaperPhoto = Image(uiImage: image)
        #else
        guard let image = NSImage(contentsOf: url) else {
            wallpaperPhoto = nil
            return
        }
        wallpaperPhoto = Image(nsImage: image)
        #endif
    }

    #if os(iOS)
    /// A wallpaper never needs to be larger than the screen it sits behind, and
    /// a full-resolution photo would be held in memory for the whole session.
    private func downscaled(_ image: UIImage, maxDimension: CGFloat = 2000) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return render(size: size) { image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// A square centre crop for the Home Screen.
    ///
    /// Square because the two widget families disagree about shape — the large
    /// one is square, the medium one a wide band through the middle — and a
    /// square source crops cleanly to either. Small, because a widget process
    /// has a fraction of the app's memory and this is only a backdrop.
    private func widgetCrop(_ image: UIImage, side: CGFloat = 1000) -> UIImage {
        let scale = side / max(1, min(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        return render(size: CGSize(width: side, height: side)) {
            image.draw(in: CGRect(
                x: (side - size.width) / 2,
                y: (side - size.height) / 2,
                width: size.width,
                height: size.height
            ))
        }
    }

    /// Renders at scale 1. `UIGraphicsImageRenderer` otherwise adopts the screen
    /// scale, which on a 3× device turns a "2000 point" downscale into a 6000
    /// pixel image — three times larger than the original it was shrinking.
    private func render(size: CGSize, draw: () -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw() }
    }
    #endif
}
