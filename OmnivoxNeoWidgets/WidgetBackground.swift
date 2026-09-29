import SwiftUI
import UIKit
import WidgetKit

/// The widget wears the same wallpaper as the app.
///
/// Photos are **cropped, never fitted**: a phone-shaped wallpaper letterboxed
/// into a wide widget would show more empty bars than photograph. The image
/// fills the widget and the overflow is cut, the way iOS crops a wallpaper to
/// the screen.
struct WidgetBackground: View {
    let appearance: SharedAppearance?

    var body: some View {
        switch appearance?.wallpaper ?? .none {
        case .none:
            defaultBackground

        case .builtIn(let id):
            if let wallpaper = BuiltInWallpaper.named(id) {
                wallpaper.gradient
            } else {
                defaultBackground
            }

        case .photo:
            photo
        }
    }

    private var defaultBackground: some View {
        Rectangle().fill(.fill.tertiary)
    }

    @ViewBuilder
    private var photo: some View {
        if let image = WidgetWallpaperPhoto.current {
            GeometryReader { geometry in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    // Blurred only here — the built-in gradients are already
                    // smooth, so blurring them would cost render time to change
                    // nothing. A photograph is the case that needs it: at widget
                    // size it becomes fine detail competing with the text on top
                    // of it, and detail nobody can make out is just noise.
                    .blur(radius: Self.blurRadius, opaque: true)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(Self.scrim)
            }
        } else {
            defaultBackground
        }
    }

    /// In points, so the blur looks the same on every device.
    ///
    /// `opaque: true` matters as much as the radius: without it the blur samples
    /// transparency from beyond the edges and the widget ends up with faded
    /// borders.
    private static let blurRadius: CGFloat = 20

    /// Widget text is `.primary`/`.secondary`, so it follows the system
    /// appearance rather than the photo underneath it. The scrim moves the
    /// photo toward whichever end of the range that text expects — pale in
    /// light mode, dark in dark mode — so a bright photo never swallows black
    /// text and a dark one never swallows white.
    /// Lighter than it would need to be on a sharp photo: the blur has already
    /// removed the busy detail, so the scrim only has to settle the overall
    /// brightness rather than hide anything.
    private static var scrim: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.34)
                : UIColor.white.withAlphaComponent(0.40)
        })
    }
}

/// Decodes the shared wallpaper once per process.
///
/// A timeline can hold dozens of entries; decoding the same JPEG for each one
/// is the quickest way to hit the widget memory limit and get killed. The
/// modification date is the cache key, so a newly chosen wallpaper is picked up
/// without a stale copy surviving in a long-lived process.
@MainActor
enum WidgetWallpaperPhoto {
    private static var cached: (stamp: Date, image: UIImage)?

    static var current: UIImage? {
        guard let url = SharedAppearance.photoURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let stamp = attributes[.modificationDate] as? Date
        else { return nil }

        if let cached, cached.stamp == stamp { return cached.image }

        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cached = (stamp, image)
        return image
    }
}
