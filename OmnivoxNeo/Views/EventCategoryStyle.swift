import SwiftUI

/// How each kind of agenda entry presents itself.
///
/// This is the one documented exception to the design system's three-colour
/// rule. The month grid marks a day with dots, and a dot has no text to carry
/// its meaning — colour *is* the label there, so the categories need to be
/// distinguishable from each other. The hues follow the portal's own legend, so
/// a student who already reads the web calendar reads this one unchanged.
///
/// Both appearances are authored. The portal's colours were picked for a white
/// page and go muddy on a dark one.
extension PortalCalendarEvent.Category {
    var tint: Color {
        switch self {
        case .academic:
            Neo.adaptiveColor(
                light: (0.20, 0.42, 0.55),
                dark: (0.47, 0.71, 0.86)
            )
        case .coursework:
            Neo.adaptiveColor(
                light: (0.75, 0.27, 0.02),
                dark: (1.00, 0.56, 0.30)
            )
        case .community:
            Neo.adaptiveColor(
                light: (0.78, 0.06, 0.48),
                dark: (1.00, 0.45, 0.76)
            )
        case .classMeeting:
            Neo.accent
        case .other:
            .secondary
        }
    }

    /// The name the student sees.
    ///
    /// Coursework is the school's own brand — "Léa" at Dawson — so it comes from
    /// that school's conventions rather than from a translation table. Renaming
    /// it in a French build would be wrong: it is called Léa in both languages.
    func label(_ conventions: PortalConventions) -> Text {
        switch self {
        case .classMeeting: Text("Class")
        case .coursework: Text(verbatim: conventions.courseworkDisplayName)
        case .academic: Text("Academic Calendar")
        case .community: Text("Community")
        case .other: Text("Other")
        }
    }

    /// The same name as a plain string, for places that cannot take a `Text` —
    /// accessibility labels and the titles written into the native calendar.
    func plainLabel(_ conventions: PortalConventions) -> String {
        switch self {
        case .classMeeting: Loc.text("Class")
        case .coursework: conventions.courseworkDisplayName
        case .academic: Loc.text("Academic Calendar")
        case .community: Loc.text("Community")
        case .other: Loc.text("Other")
        }
    }

    /// The categories the agenda shows, in the order they are offered.
    ///
    /// Classes are deliberately absent: the schedule on Home already is the
    /// student's classes, in far more detail, so repeating them here would bury
    /// the coursework and deadlines that have nowhere else to appear.
    static let agendaCategories: [PortalCalendarEvent.Category] = [
        .academic, .coursework, .community
    ]

    /// True when this belongs in the agenda at all.
    var belongsInAgenda: Bool {
        Self.agendaCategories.contains(self)
    }
}
