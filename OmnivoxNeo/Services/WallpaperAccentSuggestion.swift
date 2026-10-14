import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Picks the accent that goes with a wallpaper.
///
/// It suggests one of the nine colours the app already has rather than
/// inventing a tenth from the photograph. That is deliberate on two counts.
/// Those nine are drawn in light and dark variants chosen to stay legible
/// against text, which a colour sampled off a sunset is not; and the accent is
/// also carried to the Home Screen widget as a name, so a one-off colour would
/// have nowhere to live.
///
/// So the question is not "what colour is this photograph" but "which of these
/// nine is it most like", which is a much easier question to get right.
enum WallpaperAccentSuggestion {

    /// The accent closest to the dominant colour of an image.
    ///
    /// Returns `nil` for a photograph with no colour worth matching — a
    /// black-and-white shot, a snowfield, a night sky. Suggesting "graphite"
    /// for everything grey would be technically correct and useless, and a
    /// suggestion that is usually wrong is worse than no suggestion.
    static func accent(for imageData: Data) -> AccentChoice? {
        guard let dominant = dominantColour(in: imageData) else { return nil }
        return nearestAccent(to: dominant)
    }

    // MARK: - Finding the colour

    /// Average hue and saturation of the image, weighted towards colours that
    /// are actually colours.
    ///
    /// The image is drawn into a tiny bitmap first — the averaging does not
    /// need four thousand pixels across, and a twenty-megapixel photograph
    /// read pixel by pixel on the main thread would be felt.
    private static func dominantColour(in data: Data) -> HSB? {
        guard let cgImage = makeThumbnail(from: data, side: 48) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Hue is an angle, so it is averaged as a vector. Averaging the numbers
        // directly puts the mean of red at 350° and red at 10° somewhere around
        // cyan, which is the classic way to get this wrong.
        var x = 0.0
        var y = 0.0
        var weightTotal = 0.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let hsb = HSB(red: red, green: green, blue: blue)

            // Weighted by how colourful the pixel is, so a photograph that is
            // mostly sky with one bright roof suggests the roof. Near-black and
            // near-white pixels carry no hue worth averaging and are skipped.
            guard hsb.brightness > 0.12, hsb.brightness < 0.97, hsb.saturation > 0.12 else {
                continue
            }
            let weight = hsb.saturation * hsb.saturation
            let radians = hsb.hue * 2 * .pi
            x += cos(radians) * weight
            y += sin(radians) * weight
            weightTotal += weight
        }

        // Too little colour in the whole frame to be matching anything.
        let pixelCount = Double(width * height)
        guard weightTotal > pixelCount * 0.02 else { return nil }

        var hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        // How consistent the hues were. A frame whose colours cancel out — one
        // red wall and one green door — has a short resultant vector and no
        // single colour to suggest.
        let coherence = sqrt(x * x + y * y) / weightTotal
        guard coherence > 0.35 else { return nil }

        return HSB(hue: hue, saturation: 1, brightness: 1)
    }

    private static func makeThumbnail(from data: Data, side: Int) -> CGImage? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        #else
        guard let source = NSImage(data: data),
              let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        #endif

        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    // MARK: - Matching it to one of the nine

    private static func nearestAccent(to colour: HSB) -> AccentChoice? {
        let candidates = AccentChoice.allCases.filter { $0 != .graphite }
        var best: (choice: AccentChoice, distance: Double)?

        for candidate in candidates {
            guard let components = components(of: candidate.color) else { continue }
            let reference = HSB(
                red: components.red, green: components.green, blue: components.blue
            )
            // Distance around the hue circle, the short way round.
            let raw = abs(reference.hue - colour.hue)
            let distance = min(raw, 1 - raw)
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }

        guard let best else { return nil }
        // Further than a fifth of the way round the circle is not a match, it
        // is the least bad of nine wrong answers.
        return best.distance <= 0.2 ? best.choice : nil
    }

    private static func components(of color: Color) -> (red: Double, green: Double, blue: Double)? {
        #if canImport(UIKit)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return (Double(red), Double(green), Double(blue))
        #else
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return (
            Double(converted.redComponent),
            Double(converted.greenComponent),
            Double(converted.blueComponent)
        )
        #endif
    }
}

/// Hue, saturation and brightness, without a platform colour type in the way.
private struct HSB {
    let hue: Double
    let saturation: Double
    let brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    init(red: Double, green: Double, blue: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum

        brightness = maximum
        saturation = maximum <= 0 ? 0 : delta / maximum

        guard delta > 0 else {
            hue = 0
            return
        }
        let computed: Double
        switch maximum {
        case red:   computed = (green - blue) / delta + (green < blue ? 6 : 0)
        case green: computed = (blue - red) / delta + 2
        default:    computed = (red - green) / delta + 4
        }
        hue = computed / 6
    }
}
