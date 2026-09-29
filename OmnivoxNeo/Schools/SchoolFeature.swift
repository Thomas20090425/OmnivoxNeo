import Foundation

/// Something one school's portal supports and another's does not.
///
/// Features are declared per school in that school's own folder, and every
/// dependent piece of UI asks before it draws itself. A student signed in to a
/// school that has not declared a feature never sees it exist — no empty tab,
/// no disabled button, no "not available here" copy.
///
/// Adding a feature means: add a case here, list it in the schools that have
/// it, and gate the UI on `institution.has(...)`.
enum SchoolFeature: String, CaseIterable, Sendable {
    /// Room codes in this school's schedule can be decoded into a location,
    /// which unlocks the Campus tab.
    case campusNavigation

    /// The portal exposes an authenticator-app (TOTP) enrolment flow, so the
    /// built-in authenticator can be set up from inside the app.
    case builtInAuthenticator

    /// The portal publishes a dated events calendar — coursework, academic
    /// deadlines, campus life — beyond the class timetable. Without it the
    /// agenda has nothing to show, so the bell that opens it is not drawn.
    case agenda
}
