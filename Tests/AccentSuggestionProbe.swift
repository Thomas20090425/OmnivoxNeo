// Runs the accent suggestion against real photographs and prints what it saw.
//
//     Tests/run-accent-probe.sh NeoWallpaper/*.jpg
//
// Not a pass/fail test — there is no correct answer to "which of nine colours
// is this photograph". It exists because the only way to know whether the
// matching is any good is to look at what it decides about real images, and
// the alternative is tapping through the simulator once per photograph.

import Foundation
import SwiftUI

@main
enum AccentSuggestionProbe {
    static func main() {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            print("usage: accent-probe <image>...")
            exit(2)
        }

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else {
                print("\(url.lastPathComponent): could not be read")
                continue
            }

            let report = WallpaperAccentSuggestion.probe(for: data)
            let name = url.lastPathComponent
            guard let report else {
                print("\(name.padding(toLength: 14, withPad: " ", startingAt: 0)) no colour found")
                continue
            }

            let suggestion = report.accent.map(\.title) ?? "— none —"
            print("""
            \(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \
            hue \(String(format: "%6.1f°", report.hue * 360))  \
            coherence \(String(format: "%.2f", report.coherence))  \
            colourful \(String(format: "%.2f", report.colourfulness))  \
            -> \(suggestion)
            """)
            for (choice, distance) in report.ranked.prefix(4) {
                print("                   \(choice.title.padding(toLength: 9, withPad: " ", startingAt: 0)) "
                      + String(format: "%.3f", distance))
            }
        }
    }
}
