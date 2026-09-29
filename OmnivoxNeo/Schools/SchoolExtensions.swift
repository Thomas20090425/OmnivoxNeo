import SwiftUI

/// A screen contributed by one school, shown only to students of that school.
struct SchoolDestination: Identifiable {
    let id: String
    /// A key, so `Label` localizes it. As a `String` it picked `Label`'s
    /// verbatim overload — harmless while the only one was "Campus", which is
    /// spelled the same in French, and a silent bug for the next one.
    let title: LocalizedStringKey
    let systemImage: String
    /// One line under the title, for the row in Account.
    let subtitle: LocalizedStringKey?
    let content: AnyView

    init<Content: View>(
        id: String,
        title: LocalizedStringKey,
        systemImage: String,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = AnyView(content())
    }
}

/// Where school-specific UI plugs into the shared app.
///
/// The tab bar is the same everywhere: Home, Messages, coursework, Account.
/// Anything beyond those four is asked for here and reached from Account, so a
/// school-only screen is literally unreachable for any other school rather than
/// hidden behind a flag somewhere in the shared views.
///
/// These used to be tabs. They stopped being tabs when messaging arrived and
/// wanted the slot: a tab is for somewhere you go many times a day, and a map
/// of one college's building is somewhere you go in your first week.
@MainActor
enum SchoolExtensions {
    static func destinations(for model: AppModel) -> [SchoolDestination] {
        switch model.institution.id {
        case Dawson.institution.id:
            return Dawson.destinations(for: model)
        default:
            return []
        }
    }
}
