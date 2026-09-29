import Foundation

/// Every school the app knows how to talk to.
///
/// This is the only list. A new school is one entry here plus one folder under
/// `Schools/` holding its `Institution`, its `PortalConventions` overrides and
/// whatever UI only it gets. Nothing outside that folder should need editing.
enum SchoolCatalog {
    static let all: [Institution] = [
        Dawson.institution
    ]

    /// Resolve by stored profile id. Falls back to the first school so a
    /// profile written by a newer build — or one whose school was removed —
    /// still opens instead of crashing.
    static func school(id: String) -> Institution {
        all.first { $0.id == id } ?? all[0]
    }

    static var `default`: Institution { all[0] }
}
