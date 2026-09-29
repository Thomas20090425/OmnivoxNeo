import SwiftUI

/// Whether this screen has room to show a list and what it points at together.
///
/// Set once, at the tab bar, and read by every screen that can split. Asking
/// the size class separately in each of them is how two screens end up
/// disagreeing about what device they are on — and the answer has to be able to
/// change while the app is running, because an iPad slid into a narrow slice of
/// Split View is a phone until it is not.
private struct PrefersSplitLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var prefersSplitLayout: Bool {
        get { self[PrefersSplitLayoutKey.self] }
        set { self[PrefersSplitLayoutKey.self] = newValue }
    }
}

/// How wide the list column is allowed to get.
///
/// Deliberately phone-shaped. A list of senders or of course cards stretched
/// across half an iPad is a row of three words and then forty centimetres of
/// nothing; the same list at phone width is the thing everyone already knows
/// how to read. The screen is bigger so that the *other* column can exist, not
/// so that this one can grow.
enum SplitColumn {
    static let minWidth: CGFloat = 320
    static let idealWidth: CGFloat = 380
    static let maxWidth: CGFloat = 430
}

/// Raised by a screen that wants the whole window while it is open.
///
/// A document is the case this exists for: a PDF at half width on an iPad is
/// two columns of unreadable type, and the reader has no business knowing which
/// screen pushed it. It asks, and whichever split view is above it collapses
/// its list until the reader goes away again.
struct WantsFullWidthKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Asks the split view above this screen to stand aside while it is open.
    func wantsFullWidth(_ wants: Bool = true) -> some View {
        preference(key: WantsFullWidthKey.self, value: wants)
    }
}
