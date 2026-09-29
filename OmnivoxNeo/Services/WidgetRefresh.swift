import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Tells WidgetKit that the shared snapshot changed.
///
/// Wrapped rather than called directly so the rest of the app does not have to
/// carry the import or the availability check, and so a platform without
/// WidgetKit simply does nothing.
enum WidgetRefresh {
    static func reload() {
        #if canImport(WidgetKit) && !os(macOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
