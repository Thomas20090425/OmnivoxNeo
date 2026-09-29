import Foundation

/// The hard-coded facts about one school's OmniVox deployment.
///
/// OmniVox is themed and versioned per institution, so paths, element ids and
/// CSS classes that are stable at one college are wrong at the next. Every such
/// value belongs here, declared in that school's folder, rather than inline in
/// a scraping script where it silently becomes "the Dawson value" for everyone.
///
/// The defaults below are the stock OmniVox shape. A school that matches it
/// declares nothing; a school that differs overrides only what differs.
struct PortalConventions: Sendable, Equatable {
    // MARK: Navigation

    /// Path of the sign-in form, relative to the school's origin.
    var loginPath: String = "Login/Account/Login"
    /// Path of the authenticated landing page.
    var portalPath: String = "intr/"
    /// Path prefix the portal uses while the dashboard is still assembling.
    var dashboardLoadingPath: String = "/intr/"

    /// Any host ending here is some school's OmniVox, not the open web.
    ///
    /// Links inside portal content that point back into OmniVox need a signed-in
    /// session to mean anything, so they are recognised rather than followed.
    var portalDomainSuffix: String = "omnivox.ca"

    /// Cookies the portal sets with a future expiry that are nevertheless only
    /// good for one session.
    ///
    /// A deny-list, and that is the dangerous direction: a cookie not named
    /// here is written to the keychain as durable "this device is trusted"
    /// state. Two of these — `tksdawp`, `tksmdawp` — are Dawson's own session
    /// cookies, which is exactly why the list belongs to a school rather than
    /// to the vault. Another college's equivalent would have fallen through and
    /// been persisted, and the app would then believe it was signed in after
    /// the server had expired the session.
    var sessionOnlyCookieNames: Set<String> = [
        ".aspxomnitk",
        ".aspxroles",
        "__antixsrftoken",
        "antixsrftoken",
        "k",
        "localstoragesessionkeys",
        "resolution",
        "tkintr",
        "tkli",
        "tkphoe",
        "typeindividu",
        "typeprofil",
        "usersnbcouleurs",
        "xsrf-request-token"
    ]

    /// Name prefixes that mark a cookie as session-only, whatever follows.
    ///
    /// OmniVox mints per-school session cookies as `tks<school>p`, so the
    /// prefix catches the ones no list could enumerate in advance.
    var sessionOnlyCookiePrefixes: [String] = ["rvp-omnivox", "tks"]

    // MARK: Portal language
    //
    // The portal answers in whichever language it thinks the student wants, and
    // everything scraped out of it inherits that choice — course titles, event
    // descriptions, the lot. So the app asks for its *own* language rather than
    // letting the portal guess.

    /// Query parameter that selects the page language.
    ///
    /// OmniVox stamps it on every link it generates (`…&L=ANG&…`), which is how
    /// it is known; a school that uses a different name changes it here.
    var languageQueryName: String = "L"

    /// Portal language codes, keyed by ISO language code.
    ///
    /// A language with no entry is simply not requested — the portal then falls
    /// back to its own default, which is the right outcome for a language it
    /// does not publish in.
    var languageCodes: [String: String] = ["en": "ANG", "fr": "FRA"]

    /// Adds the language parameter to a portal URL, if this school has a code
    /// for the requested language and the URL does not already carry one.
    func localizedPortalURL(_ url: URL, languageCode: String?) -> URL {
        guard
            let languageCode,
            let portalCode = languageCodes[languageCode],
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }

        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == languageQueryName }) else { return url }
        items.append(URLQueryItem(name: languageQueryName, value: portalCode))
        components.queryItems = items
        return components.url ?? url
    }

    // MARK: Sign-in form

    var loginFormSelector: String = #"#formLogin, form[name="formLogin"]"#
    var studentIDFieldSelector: String = #"#Identifiant, input[name="NoDA"]"#
    var passwordFieldSelector: String = #"#Password, input[name="PasswordEtu"], input[type="password"]"#

    // MARK: Authenticated dashboard

    /// Presence of this element means the dashboard finished rendering.
    var dashboardReadySelector: String = "#ovx10_wrap_calendrier"
    /// Where the signed-in student's name is printed.
    var profileNameSelector: String = "#headerNavbarProfileUserName"

    // MARK: Agenda
    //
    // The events list is the densest thing the app scrapes, so it has the most
    // to gain from being described here: a school that reskins its calendar
    // changes these lines and nothing else.

    /// The block containing the month calendar and the events list.
    var calendarRootSelector: String = "#ovx10_wrap_calendrier"
    /// One event inside a day's list.
    var eventSelector: String = ".liste-evenements > .evenement"
    /// The day an event belongs to. Its `data-date` is `start|end`.
    var eventDaySelector: String = ".bloc-jour[data-date]"
    /// Hidden element carrying the full, unclipped event in `data-` attributes.
    var eventDataSelector: String = ".modal-data"
    var eventTitleSelector: String = ".evenement-titre"
    var eventDescriptionSelector: String = ".evenement-description"
    /// The course code, italicised inside a class event's description.
    var eventCourseCodeSelector: String = ".evenement-description em"
    /// The room, emboldened inside a class event's description.
    var eventRoomSelector: String = ".evenement-description strong"
    /// The course name repeated under an event's type line.
    var eventTypeDetailSelector: String = ".evenement-type span"
    /// Shown by the portal when a period genuinely has no events, as opposed to
    /// the list simply not having loaded yet.
    var emptyAgendaSelector: String = ".no-item:not(.filtered-out):not([disabled])"

    // MARK: Event categories
    //
    // The codes the portal stamps on every event. They are shared across the
    // OmniVox family today, which is exactly why they are worth naming: when one
    // school diverges, this is the only place that has to know.

    var classMeetingCategoryCode: String = "COURS"
    var courseworkCategoryCode: String = "LEA"
    var academicCategoryCode: String = "CALSCOLAIRE"
    var communityCategoryCode: String = "COMMUNAUTE"

    /// What the school calls its coursework system.
    ///
    /// "Léa" is the OmniVox name students actually see, so the app uses it
    /// rather than inventing a synonym — but it is a brand, not a category, and
    /// a school that renames it renames it here.
    var courseworkDisplayName: String = "Léa"

    /// What the school calls its internal messaging.
    ///
    /// Same reasoning as above, and the reason the tab does not say "Messages":
    /// a student looking for the thing their teacher told them to check is
    /// looking for the word the college uses, which here is MIO.
    var messagingDisplayName: String = "MIO"

    // MARK: What's new

    /// Cards announcing new documents, grades and assignments.
    var whatsNewCardSelector: String = "#ovx10_wrap_QDN a.carte-QDN"
    var cardTitleSelector: String = ".carte-portail-titre"
    var cardDetailSelector: String = ".carte-portail-desc"

    // MARK: Multi-factor verification

    /// Every verification page lives under this path.
    var mfaLoginPathPrefix: String = "/apps/mfa/login/"
    /// Href fragment of the "use another method" link.
    var mfaMethodsPathFragment: String = "/apps/mfa/login/validation-methods/"
    /// Href fragment of a single method's code page. Method cards use it too,
    /// which is why anything matching it has to be filtered by element class.
    var mfaValidateMethodPathFragment: String = "/apps/mfa/login/validate-method/"
    /// The tappable cards on the "choose a method" page.
    var methodCardSelector: String = "a.MuiCardActionArea-root"
    /// `data-testid` of the icon that marks the authenticator-app method.
    var authenticatorIconTestID: String = "SystemSecurityUpdateGoodIcon"
    /// Where the code was sent — the masked phone number or address.
    var verificationDestinationSelector: String = "p.MuiTypography-noWrap"
    /// The six-digit code field, which the app re-tags for the numeric keypad
    /// and one-time-code autofill.
    var verificationCodeFieldSelector: String = #"input[maxlength="6"], input[maxLength="6"]"#

    /// Words the portal prints on the verification screen, as JavaScript
    /// regular-expression sources.
    ///
    /// The portal writes these in whichever language the student is browsing
    /// in, and OmniVox's English is machine-translated from the French — "To
    /// validate" rather than "Validate". They are vocabulary, not markup, so
    /// they belong to a school rather than to the script that reads them.
    var trustedDevicePattern: String = #"trusted device|appareil.*confiance|ordinateur.*confiance"#
    var validateButtonPattern: String = #"^(to\s+)?validate$|^valider$"#
    var resendCodePattern: String = #"request|new code|nouveau"#

    /// What the portal writes on the control that removes a registered
    /// authenticator, in each language it publishes.
    ///
    /// Matched case-insensitively, because MUI uppercases these with CSS while
    /// `textContent` returns the source text — so a build that writes "Delete"
    /// rather than "DELETE" used to match nothing, and re-enrolment failed with
    /// a bare navigation error and no way to tell why.
    var deleteAuthenticatorLabels: [String] = ["delete", "supprimer"]

    // MARK: Authenticator enrolment

    /// Where a student manages their verification methods.
    var mfaSettingsPath: String = "/apps/mfa/validation-methods"
    /// Where a new authenticator app is enrolled.
    var totpCreatePath: String = "/apps/mfa/validation-methods/totp/create"
    /// Element holding the shared secret once it is revealed.
    var totpSecretSelector: String = ".MuiTypography-button"

    // MARK: Léa

    /// The classroom product behind the portal, described separately because it
    /// is a separate product: different host, different generation of markup.
    var lea: LeaConventions = .skytechStock

    /// And the messaging module, which is a third product again.
    var mio: MioConventions = .omnivoxStock

    static let omnivoxStock = PortalConventions()

    /// The subset the in-page scripts need, as a JSON object literal.
    ///
    /// Injected once at the top of a script so the page code reads named
    /// values instead of carrying one school's strings inline — which is what
    /// made them impossible to vary in the first place.
    var javascriptDescriptor: String {
        let fields: [String: String] = [
            "loginForm": loginFormSelector,
            "studentIDField": studentIDFieldSelector,
            "passwordField": passwordFieldSelector,
            "dashboardReady": dashboardReadySelector,
            "dashboardLoadingPath": dashboardLoadingPath,
            "profileName": profileNameSelector,
            "calendarRoot": calendarRootSelector,
            "event": eventSelector,
            "eventDay": eventDaySelector,
            "eventData": eventDataSelector,
            "eventTitle": eventTitleSelector,
            "eventDescription": eventDescriptionSelector,
            "eventCourseCode": eventCourseCodeSelector,
            "eventRoom": eventRoomSelector,
            "eventTypeDetail": eventTypeDetailSelector,
            "emptyAgenda": emptyAgendaSelector,
            "classMeetingCode": classMeetingCategoryCode,
            "whatsNewCard": whatsNewCardSelector,
            "cardTitle": cardTitleSelector,
            "cardDetail": cardDetailSelector,
            "mfaPrefix": mfaLoginPathPrefix,
            "mfaMethodsFragment": mfaMethodsPathFragment,
            "mfaValidateFragment": mfaValidateMethodPathFragment,
            "methodCard": methodCardSelector,
            "authenticatorIcon": authenticatorIconTestID,
            "verificationDestination": verificationDestinationSelector,
            "verificationCodeField": verificationCodeFieldSelector
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: fields,
                options: [.sortedKeys]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
}
