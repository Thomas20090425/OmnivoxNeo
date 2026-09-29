import Foundation

/// The hard-coded facts about one school's Léa.
///
/// Léa is a separate product from the portal that fronts it — different host,
/// different generation of markup — so its selectors live in their own type
/// rather than swelling `PortalConventions` with a second vocabulary.
///
/// The defaults are the stock Skytech shape. The values that matter most are
/// the SVG symbol ids: Léa labels every section of a course card in the
/// student's own language, but draws the same `<use href="#msgs">` underneath
/// regardless, so the icon is the only language-independent name these rows
/// have. Matching on the label would mean the app worked in English and
/// quietly showed nothing in French.
struct LeaConventions: Sendable, Equatable {
    // MARK: Reaching Léa

    /// The shortcut on the portal home that performs the SSO hop into Léa.
    ///
    /// Followed rather than reconstructed: the href carries a freshly minted
    /// `Ref` and service identifiers, and a hand-built URL is a signed-out one.
    var portalShortcutSelector: String =
        #"a.code-groupe_lea, a[class*="code-groupe_lea"], a[href*="IdService=CVIE"]"#

    /// Recognises a Léa page once it has loaded.
    var homeReadySelector: String = ".classes-wrapper, #tblDocuments, .table-notes"

    // MARK: Course cards

    var courseCardSelector: String = ".classes-wrapper .card-panel"
    var courseTitleSelector: String = ".card-panel-title"
    var courseSubtitleSelector: String = ".card-panel-desc"
    /// Léa tags each card header with `card-panel-header-bg-N`.
    var coursePaletteClassPrefix: String = "card-panel-header-bg-"

    var sectionRowSelector: String = ".card-panel-item-wrapper"
    var sectionTitleSelector: String = ".item-header-title"
    var sectionTrailingSelector: String = ".item-header-element"
    var metricRowSelector: String = ".item-content-row"
    var metricLabelSelector: String = ".left-section"
    var metricValueSelector: String = ".right-section"
    var metricCountSelector: String = ".file-indicator-number"
    var metricNewSelector: String = ".nouveaute"

    var announcementRowSelector: String = ".communique-date-title-wrapper"
    var announcementNewSelector: String = ".nouveau-communique"

    /// SVG symbol ids, mapped to the section they mark.
    var sectionSymbolIDs: [String: String] = [
        "cade": "onlineClass",
        "document_video": "documents",
        "rtrv": "assignments",
        "noteeval": "grades",
        "msgs": "announcements",
        "abs": "absences"
    ]

    /// Material icon ligatures, for the two rows Léa draws with a font instead
    /// of a symbol.
    var sectionMaterialIcons: [String: String] = [
        "calendar_today": "events",
        "forum": "forum"
    ]

    /// What Léa prints beside "Online class" when the class meets in person.
    ///
    /// Anything else is a delivery mode this app does not model, and the
    /// student is pointed at the official client rather than shown a guess.
    var inPersonClassKeywords: [String] = ["classroom", "classe", "salle"]

    // MARK: Term picker

    /// Léa's term menu — a hidden table, not a `<select>`.
    ///
    /// Every row carries `DoSelect('session', '20263', null, 'v3')` in its
    /// `onclick`, which is both where the term's value is written down and how
    /// the term is changed. Nothing marks the current one.
    var termTableSelector: String = "#tblChoixCoursGroupeSession, table.tblMenuSelection"

    /// The control that opens that menu, whose label is the current term.
    var termTriggerSelector: String =
        #".cgSelect-table a[onmouseover*="'session'"], a[onmouseover*="ExpandDropDownStartWait('session'"]"#

    /// Léa's own function for switching term. Called directly rather than by
    /// clicking the row, whose handler first raises an unsaved-changes prompt
    /// for a form this app never filled in.
    var termSelectFunction: String = "DoSelect"

    /// The shape of the call, with the value left to fill in.
    func termSelectCall(value: String) -> String {
        "\(termSelectFunction)('session', '\(value)', null, 'v3')"
    }

    /// The other thing that picker chooses: which class a module is showing.
    ///
    /// Léa's per-course links — grades, assignments — open the module, not the
    /// course. Which class the module shows is held in the session rather than
    /// in the address, so following one of those links in a session that has
    /// not chosen a class renders the navigation and an empty body. The same
    /// `DoSelect` control chooses it, with this key in place of `session`.
    var classSelectKey: String = "groupe"

    /// Léa's own left-hand link to the recommended-websites service.
    ///
    /// Matched by the service code OmniVox stamps on the element id rather than
    /// by the label, which is translated.
    var recommendedSitesNavSelector: String =
        #"#lienPERE, [id*="PERE"] a[href], a[href*="IdService=PERE"]"#

    // MARK: Announcements

    var announcementTitleSelector: String = ".TitreAnnonce"
    var announcementCourseSelector: String = ".TitreCoursGroupe"
    var announcementBodySelector: String = ".Contenu"

    // MARK: Documents

    var documentCategorySelector: String = "table.CategorieDocument"
    var documentCategoryTitleSelector: String = ".DisDoc_TitreCategorie"
    var documentRowSelector: String = #"tr[id^="doc"]"#
    var documentTitleSelector: String = ".lblTitreDocumentDansListe"
    var documentDescriptionSelector: String = ".divDescriptionDocumentDansListe"
    var documentAvailabilitySelector: String = ".DocDispo"
    var documentDownloadCellSelector: String = ".colVoirTelecharger"
    /// The star Léa puts beside a document the student has never opened.
    var documentUnreadSelector: String = ".classeEtoileNouvDoc"
    /// Wrapper Léa uses for teacher-recommended external links.
    var documentExternalLinkFunction: String = "ValiderLienDocExterne"
    /// Léa's own opener for a distributed file, when the title is a
    /// `javascript:` link rather than an href.
    ///
    /// The only route to a document's URL in that case, so a Léa build that
    /// renames it leaves every document in every course unopenable — the list
    /// still renders and the rows simply do nothing.
    var documentOpenFunction: String = "CallPageVisualiseDocument"

    // MARK: Assignments

    var assignmentTableSelector: String = "#tabListeTravEtu"
    var assignmentCategorySelector: String = ".TitreCategorie"
    /// The pop-up opener Léa wraps every assignment title in.
    var assignmentOpenFunction: String = "OpenCentre"
    var assignmentSubmissionPathFragment: String = "ReadDepotEtudiant"
    var assignmentCorrectedPathFragment: String = "ReadDepotCorrige"
    var assignmentSubmitPathFragment: String = "DepotTravail.aspx"
    /// The star beside instructions that have never been retrieved.
    var assignmentUnreadSelector: String = #"img[src*="TravailNonVisualise"]"#
    /// How Léa says a deadline has passed: it colours the date red and says
    /// nothing else at all.
    ///
    /// Matched against the inline style with its spaces removed, so the
    /// several ways of writing the same colour all count. Still a presentation
    /// detail standing in for a fact, which is why it is declared here where a
    /// school can correct it rather than buried in the script.
    var assignmentOverdueStylePatterns: [String] = [
        "color:red", "color:#f00", "color:#ff0000", "color:rgb(255,0,0)", "color:crimson"
    ]
    /// Léa's own "Close" control inside the submission pop-up, hidden so the
    /// sheet has one way out instead of two that disagree.
    var assignmentCloseButtonSelector: String = "#btnAnnuler"

    // MARK: Grades

    var gradeTableSelector: String = "table.table-notes"
    var gradeCategoryRowSelector: String = "tr.tr-header-cat"
    var gradePositionSelector: String = "td.td-nombre"
    var gradeSummarySelector: String = "table.tb-sommaire"
    var gradeProgressionImageSelector: String = "#graphEvo"
    /// The hidden tooltips behind that image, one per plotted point, each
    /// spelling out the average, the cumulative weight and the date in words.
    var gradeProgressionPointSelector: String = #"div[id^="pt"]"#
    /// How Léa draws a mark it is going to drop from the average: greyed out.
    ///
    /// A presentation detail standing in for a fact, which is why it is
    /// declared here where a school can correct it rather than buried in the
    /// script. It is only ever believed inside a category that has announced a
    /// drop rule — grey on its own is just grey, and telling a student a mark
    /// does not count when it does is worse than saying nothing.
    /// Two hashes, not one: the selector itself contains `="#`, which is how a
    /// `#"…"#` literal ends.
    var gradeDiscardedMarkSelector: String =
        ##"font[color="#777777"], font[color="gray"], font[color="grey"], [style*="777777"]"##
    /// The marker Léa uses in a comment block's heading.
    var gradeCommentMarkers: [String] = ["left this comment", "a laissé ce commentaire", "commentaire"]
    /// What Léa prints where a mark has not been released.
    var unreleasedGradeMarker: String = "-"

    // MARK: Recommended websites

    var teacherSitesRowSelector: String = #"td[class^="InfoProfEtuContenu"]"#
    var teacherSitesLinkFragment: String = "OID="
    var siteCategorySelector: String = ".Lien_TitreCategorie"
    var siteLinkSelector: String = ".Lien_LienSite"
    var siteURLSelector: String = ".Lien_Gris"
    var siteRowSelector: String = ".Lien_LienSiteDescription"

    static let skytechStock = LeaConventions()

    /// The subset the in-page scripts need, as a JSON object literal.
    var javascriptDescriptor: String {
        let strings: [String: Any] = [
            "courseCard": courseCardSelector,
            "courseTitle": courseTitleSelector,
            "courseSubtitle": courseSubtitleSelector,
            "palettePrefix": coursePaletteClassPrefix,
            "sectionRow": sectionRowSelector,
            "sectionTitle": sectionTitleSelector,
            "sectionTrailing": sectionTrailingSelector,
            "metricRow": metricRowSelector,
            "metricLabel": metricLabelSelector,
            "metricValue": metricValueSelector,
            "metricCount": metricCountSelector,
            "metricNew": metricNewSelector,
            "announcementRow": announcementRowSelector,
            "announcementNew": announcementNewSelector,
            "symbols": sectionSymbolIDs,
            "materialIcons": sectionMaterialIcons,
            "termTable": termTableSelector,
            "termTrigger": termTriggerSelector,
            "termSelectFunction": termSelectFunction,
            "classSelectKey": classSelectKey,
            "homeReady": homeReadySelector,
            "announcementTitle": announcementTitleSelector,
            "announcementCourse": announcementCourseSelector,
            "announcementBody": announcementBodySelector,
            "documentCategory": documentCategorySelector,
            "documentCategoryTitle": documentCategoryTitleSelector,
            "documentRow": documentRowSelector,
            "documentTitle": documentTitleSelector,
            "documentDescription": documentDescriptionSelector,
            "documentAvailability": documentAvailabilitySelector,
            "documentDownloadCell": documentDownloadCellSelector,
            "documentUnread": documentUnreadSelector,
            "externalLinkFunction": documentExternalLinkFunction,
            "assignmentTable": assignmentTableSelector,
            "assignmentCategory": assignmentCategorySelector,
            "assignmentOpenFunction": assignmentOpenFunction,
            "submissionFragment": assignmentSubmissionPathFragment,
            "correctedFragment": assignmentCorrectedPathFragment,
            "submitFragment": assignmentSubmitPathFragment,
            "assignmentUnread": assignmentUnreadSelector,
            "assignmentOverdueStyles": assignmentOverdueStylePatterns,
            "documentOpenFunction": documentOpenFunction,
            "gradeTable": gradeTableSelector,
            "gradeCategoryRow": gradeCategoryRowSelector,
            "gradePosition": gradePositionSelector,
            "gradeSummary": gradeSummarySelector,
            "gradeProgressionImage": gradeProgressionImageSelector,
            "gradeProgressionPoint": gradeProgressionPointSelector,
            "gradeDiscarded": gradeDiscardedMarkSelector,
            "gradeCommentMarkers": gradeCommentMarkers,
            "unreleasedGrade": unreleasedGradeMarker,
            "teacherSitesRow": teacherSitesRowSelector,
            "teacherSitesLinkFragment": teacherSitesLinkFragment,
            "siteCategory": siteCategorySelector,
            "siteLink": siteLinkSelector,
            "siteURL": siteURLSelector,
            "siteRow": siteRowSelector,
            "portalShortcut": portalShortcutSelector,
            "recommendedSitesNav": recommendedSitesNavSelector
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: strings, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
}
