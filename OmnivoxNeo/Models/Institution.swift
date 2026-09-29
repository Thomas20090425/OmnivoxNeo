import Foundation

/// One school, and everything the shared app needs to know to talk to it.
///
/// Instances are not declared here — each school defines its own under
/// `Schools/<Name>/`, and `SchoolCatalog` collects them. That keeps a school's
/// quirks in its own folder instead of spreading through shared code.
struct Institution: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let origin: URL
    let timeZoneIdentifier: String

    /// The hard-coded paths and selectors for this school's OmniVox build.
    var conventions: PortalConventions = .omnivoxStock

    /// What this school's portal supports. UI that depends on a feature must
    /// ask `has(_:)` before drawing itself.
    var features: Set<SchoolFeature> = []

    var host: String {
        origin.host ?? ""
    }

    var loginURL: URL {
        origin.appending(path: conventions.loginPath)
    }

    var portalURL: URL {
        origin.appending(path: conventions.portalPath)
    }

    var displayedLoginAddress: String {
        loginURL.absoluteString
    }

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    func has(_ feature: SchoolFeature) -> Bool {
        features.contains(feature)
    }

    func owns(_ url: URL?) -> Bool {
        guard
            let url,
            url.scheme?.lowercased() == "https",
            let candidateHost = url.host?.lowercased(),
            url.port == nil || url.port == 443
        else {
            return false
        }
        return candidateHost == host.lowercased()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Institution, rhs: Institution) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Catalog access
    //
    // Kept as forwarding members so existing call sites keep reading naturally.

    nonisolated static var all: [Institution] { SchoolCatalog.all }

    nonisolated static var dawson: Institution { Dawson.institution }

    nonisolated static func named(_ id: String) -> Institution {
        SchoolCatalog.school(id: id)
    }
}
