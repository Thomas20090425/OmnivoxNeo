import SwiftUI

/// Dawson College.
///
/// Everything specific to Dawson lives in this folder: its portal conventions,
/// the features it gets, and the screens only its students see. Nothing here is
/// referenced by the shared app except through `SchoolCatalog` and
/// `SchoolExtensions`.
enum Dawson {
    static let institution = Institution(
        id: "dawson",
        displayName: "Dawson College",
        origin: URL(string: "https://dawsoncollege.omnivox.ca/")!,
        timeZoneIdentifier: "America/Toronto",
        conventions: conventions,
        features: [
            .campusNavigation,
            .builtInAuthenticator,
            .agenda
        ]
    )

    /// Dawson runs the stock OmniVox build, so it overrides nothing today.
    /// When it diverges — or when a second school is added and one of the
    /// shared defaults turns out to have been Dawson's value all along — the
    /// override goes here rather than in the scraping code.
    static let conventions = PortalConventions.omnivoxStock

    /// Screens only Dawson students get, reached from Account.
    @MainActor
    static func destinations(for model: AppModel) -> [SchoolDestination] {
        var places: [SchoolDestination] = []

        if institution.has(.campusNavigation) {
            places.append(
                SchoolDestination(
                    id: "dawson.campus",
                    title: "Campus",
                    systemImage: "map.fill",
                    subtitle: "Find a room from its code"
                ) {
                    DawsonCampusView(model: model)
                }
            )
        }

        return places
    }
}
