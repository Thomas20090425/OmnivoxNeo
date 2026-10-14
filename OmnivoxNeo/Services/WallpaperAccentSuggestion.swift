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

    /// What the matcher saw, for checking it against real photographs.
    struct Probe {
        let hue: Double
        /// How much the hues agreed with each other, 0 to 1. A frame with one
        /// red wall and one green door cancels out and scores low.
        let coherence: Double
        /// What fraction of the frame carried any colour at all.
        let colourfulness: Double
        let accent: AccentChoice?
        /// Every candidate and its distance, nearest first.
        let ranked: [(AccentChoice, Double)]
    }

    /// The accent closest to the dominant colour of an image.
    ///
    /// Returns `nil` for a photograph with no colour worth matching — a
    /// black-and-white shot, a snowfield, a night sky. Suggesting "graphite"
    /// for everything grey would be technically correct and useless, and a
    /// suggestion that is usually wrong is worse than no suggestion.
    static func accent(for imageData: Data) -> AccentChoice? {
        probe(for: imageData)?.accent
    }

    /// The same thing, with its working shown. Used by `Tests/run-accent-probe.sh`.
    static func probe(for imageData: Data) -> Probe? {
        guard let measurement = measure(imageData) else { return nil }
        let ranked = rank(colour: measurement.colour)
        let accent = chooseAccent(from: ranked, measurement: measurement)
        return Probe(
            hue: measurement.hue,
            coherence: measurement.coherence,
            colourfulness: measurement.colourfulness,
            accent: accent,
            ranked: ranked
        )
    }

    // MARK: - Finding the colour

    /// Average hue and saturation of the image, weighted towards colours that
    /// are actually colours.
    ///
    /// The image is drawn into a tiny bitmap first — the averaging does not
    /// need four thousand pixels across, and a twenty-megapixel photograph
    /// read pixel by pixel on the main thread would be felt.
    private struct Measurement {
        let hue: Double
        /// The dominant cluster as an actual colour, not just its angle.
        let colour: (Double, Double, Double)
        let coherence: Double
        let colourfulness: Double
    }

    private static func measure(_ data: Data) -> Measurement? {
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

        // A histogram, and the *mode* — not the mean.
        //
        // Averaging hue across a photograph was the first attempt and it is
        // wrong twice over. A picture is not one colour, so the mean of a
        // green canopy and an orange path is a yellow that appears nowhere in
        // it; and weighting by saturation squared let a handful of vivid
        // leaves outvote the whole canopy behind them. A wallpaper's accent
        // should come from what actually covers the screen, so the weight is
        // linear in saturation and the answer is the biggest cluster.
        var histogram = [Double](repeating: 0, count: binCount)
        var sums = [(red: Double, green: Double, blue: Double)](
            repeating: (0, 0, 0), count: binCount
        )
        var weightTotal = 0.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let hsb = HSB(red: red, green: green, blue: blue)
            // Near-black, near-white and near-grey pixels carry no hue worth
            // counting — a dark tree trunk is not a colour decision.
            guard hsb.brightness > 0.12, hsb.brightness < 0.97, hsb.saturation > 0.15 else {
                continue
            }
            let bin = min(binCount - 1, Int(hsb.hue * Double(binCount)))
            histogram[bin] += hsb.saturation
            // Kept so the winning cluster can be turned back into an actual
            // colour. Hue alone throws away everything that distinguishes
            // sunlit foliage from a traffic cone.
            sums[bin].red += red * hsb.saturation
            sums[bin].green += green * hsb.saturation
            sums[bin].blue += blue * hsb.saturation
            weightTotal += hsb.saturation
        }

        guard weightTotal > 0 else { return nil }

        // Smoothed around the circle before picking a peak, so a hue sitting
        // on a bin boundary is not split in half and beaten by a lesser one.
        var smoothed = [Double](repeating: 0, count: binCount)
        for bin in 0..<binCount {
            let previous = histogram[(bin + binCount - 1) % binCount]
            let next = histogram[(bin + 1) % binCount]
            smoothed[bin] = previous * 0.5 + histogram[bin] + next * 0.5
        }

        guard let peak = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }) else {
            return nil
        }

        // The winning cluster, averaged back into a real colour rather than
        // reduced to an angle.
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var clusterMass = 0.0
        for offset in -1...1 {
            let bin = (peak + offset + binCount) % binCount
            let mass = histogram[bin]
            guard mass > 0 else { continue }
            red += sums[bin].red
            green += sums[bin].green
            blue += sums[bin].blue
            clusterMass += mass
        }
        guard clusterMass > 0 else { return nil }

        let colour = (red / clusterMass, green / clusterMass, blue / clusterMass)

        return Measurement(
            hue: HSB(red: colour.0, green: colour.1, blue: colour.2).hue,
            colour: colour,
            // How much of the colour in the frame belongs to the winning
            // cluster. A picture split evenly between two unrelated colours
            // scores low, and gets no suggestion.
            coherence: clusterMass / weightTotal,
            colourfulness: weightTotal / Double(width * height)
        )
    }

    /// Ten degrees per bin: fine enough to tell orange from red, coarse enough
    /// that one tree does not become its own cluster.
    private static let binCount = 36

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

    /// Every candidate and how far it is from the measured colour, nearest
    /// first. Graphite is excluded: it has no hue, so every distance to it
    /// would be meaningless.
    ///
    /// Compared in CIELAB's colour plane rather than by hue angle, which is
    /// the fix for the case that made this worth checking. Sunlit foliage
    /// measures as yellow-green, and in HSV that sits 45° from orange and 71°
    /// from green — so a photograph of a forest was being matched to Orange.
    /// Lab is built so that equal distances look equally different, and there
    /// yellow-green falls where a person would put it: nearer the green.
    ///
    /// Lightness is dropped, so only the colour is compared. A dark forest and
    /// a bright one should get the same accent; the accents have their own
    /// light and dark variants and do not need to match the photograph's
    /// exposure.
    private static func rank(colour: (Double, Double, Double)) -> [(AccentChoice, Double)] {
        let target = Lab(red: colour.0, green: colour.1, blue: colour.2)
        return AccentChoice.allCases
            .filter { $0 != .graphite }
            .compactMap { candidate -> (AccentChoice, Double)? in
                guard let components = components(of: candidate.color) else { return nil }
                let reference = Lab(
                    red: components.red, green: components.green, blue: components.blue
                )
                let deltaA = reference.a - target.a
                let deltaB = reference.b - target.b
                // Scaled to roughly 0...1 over the usable gamut, so the
                // threshold below reads as a fraction rather than as a number
                // only this file understands.
                return (candidate, sqrt(deltaA * deltaA + deltaB * deltaB) / 180)
            }
            .sorted { $0.1 < $1.1 }
    }

    private static func chooseAccent(
        from ranked: [(AccentChoice, Double)],
        measurement: Measurement
    ) -> AccentChoice? {
        guard let best = ranked.first else { return nil }
        // Three ways a photograph earns no suggestion, each of them a case
        // where the nearest accent would be the least bad of nine wrong
        // answers rather than a match:
        //
        //  - almost nothing in the frame carries colour (a snowfield, a
        //    black-and-white shot, a night sky);
        //  - the colours that are there disagree, so their average is a hue
        //    that appears nowhere in the picture;
        //  - the winner is still most of the way round the circle.
        guard measurement.colourfulness >= 0.04 else { return nil }
        guard measurement.coherence >= 0.45 else { return nil }
        guard best.1 <= 0.42 else { return nil }

        // And one more: the winner has to have actually won. A night street
        // of brown brick and amber light comes out almost equidistant from
        // orange, teal and green — which is not a close contest between three
        // good answers, it is a muddy colour that is near the middle of
        // everything. A dead heat means there was nothing to find.
        if ranked.count > 1 {
            let margin = ranked[1].1 - best.1
            guard margin >= 0.05 else { return nil }
        }
        return best.0
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

/// CIELAB, for comparing colours the way eyes do rather than the way RGB does.
///
/// Only `a` and `b` are used — the colour plane. `L` is kept for completeness
/// and because leaving it out of the conversion would be more confusing than
/// including it.
private struct Lab {
    let l: Double
    let a: Double
    let b: Double

    init(red: Double, green: Double, blue: Double) {
        // sRGB is gamma-encoded; everything below assumes light, not signal.
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let r = linear(red)
        let g = linear(green)
        let bl = linear(blue)

        // sRGB primaries to CIEXYZ, D65.
        let x = (r * 0.4124564 + g * 0.3575761 + bl * 0.1804375) / 0.95047
        let y = r * 0.2126729 + g * 0.7151522 + bl * 0.0721750
        let z = (r * 0.0193339 + g * 0.1191920 + bl * 0.9503041) / 1.08883

        func f(_ value: Double) -> Double {
            value > 0.008856 ? pow(value, 1.0 / 3) : (7.787 * value) + (16.0 / 116)
        }
        let fx = f(x)
        let fy = f(y)
        let fz = f(z)

        l = (116 * fy) - 16
        a = 500 * (fx - fy)
        b = 200 * (fy - fz)
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
