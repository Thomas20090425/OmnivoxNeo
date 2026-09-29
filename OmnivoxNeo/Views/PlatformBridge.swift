import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The two small places UIKit and AppKit disagree, named once.
///
/// This app is one target building for both iPhone and Mac, and almost all of
/// it is plain SwiftUI that does not care. The exceptions are the clipboard and
/// the escape hatch into a platform view — and both were being handled by
/// `#if` blocks copied from file to file, which is how one of the copies ends
/// up fixed and the others do not.

// MARK: - The clipboard

enum Pasteboard {
    /// Puts text on the clipboard.
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// What is currently on the clipboard, if it is text.
    ///
    /// On iOS, reading this shows the system's paste banner, so it is only ever
    /// called where the student has just been asked to copy something.
    static var text: String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    /// Empties it.
    ///
    /// Used before asking for a secret to be pasted, so what comes back is
    /// known to be new rather than whatever happened to be there already.
    static func clear() {
        #if canImport(UIKit)
        UIPasteboard.general.string = ""
        #else
        NSPasteboard.general.clearContents()
        #endif
    }
}

// MARK: - Wrapping a platform view

#if canImport(UIKit)
typealias PlatformViewRepresentable = UIViewRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
#endif
