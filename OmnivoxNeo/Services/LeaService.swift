import Foundation
import WebKit

/// Reads Léa.
///
/// Léa is reached by an SSO hop from the portal and then served from its own
/// host, so it cannot be fetched with a plain request: the hop mints the
/// session. This drives a second, offscreen `WKWebView` that shares the signed
/// in profile's cookie jar with the one the rest of the app uses, follows the
/// shortcut once, and then reads pages by injecting a script that returns JSON.
///
/// Separate from `AppModel`'s web view on purpose. That one is a state machine
/// for signing in; borrowing it would mean every Léa page load had to be
/// understood by the authentication code, and a scrape landing mid-login would
/// be indistinguishable from the portal bouncing the student out.
@MainActor
final class LeaService: NSObject {
    /// A failed read, carrying its own already-localized message.
    ///
    /// A struct rather than an enum with computed text: `LocalizedError` is
    /// reached from wherever the error surfaces, and `Loc` is main-actor bound,
    /// so the sentence is resolved at the throw site and simply carried.
    struct Failure: LocalizedError {
        /// True when the page came back as a sign-in form. The caller uses this
        /// to offer a refresh rather than an apology.
        let isSessionExpired: Bool
        let message: String

        var errorDescription: String? { message }

        @MainActor
        static var unavailable: Failure {
            Failure(
                isSessionExpired: false,
                message: Loc.text("Léa is not available for this account.")
            )
        }

        @MainActor
        static var sessionExpired: Failure {
            Failure(
                isSessionExpired: true,
                message: Loc.text("Your Léa session expired. Pull to refresh and try again.")
            )
        }

        static func unreadable(_ detail: String) -> Failure {
            Failure(isSessionExpired: false, message: detail)
        }

        static func navigation(_ detail: String) -> Failure {
            Failure(isSessionExpired: false, message: detail)
        }
    }

    private let institution: Institution
    private let webView: WKWebView
    /// Downloads run on `webView` itself — see `downloadDocument(titled:on:)`.
    private lazy var downloader: PortalDownloader = {
        let downloader = PortalDownloader(webView: webView)
        downloader.onProgress = { [weak self] fraction in
            self?.onDownloadProgress?(fraction)
        }
        return downloader
    }()

    /// Reported straight through to the store, which is what the row draws.
    var onDownloadProgress: ((Double?) -> Void)?
    private var pendingNavigation: CheckedContinuation<Void, Error>?
    /// Where Léa's landing page turned out to live, once the hop has happened.
    private(set) var homeURL: URL?

    private var conventions: LeaConventions { institution.conventions.lea }

    init(institution: Institution, websiteDataStore: WKWebsiteDataStore) {
        self.institution = institution

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.applicationNameForUserAgent = AppModel.portalUserAgentProduct
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 2_048), configuration: configuration)

        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Reaching Léa

    /// Follows the portal's Léa shortcut, once per session.
    ///
    /// The href is read off the page rather than rebuilt: it carries a freshly
    /// minted `Ref` and the service identifiers that make the hop work, and a
    /// hand-assembled URL lands on a sign-in wall.
    @discardableResult
    func openHome() async throws -> URL {
        // Knowing the address is not the same as being on the page. This used
        // to return the cached URL without navigating at all, on the reasoning
        // that the hop had already happened — but by then the web view has
        // usually been sent somewhere else, to a documents list or to whatever
        // page a term switch posted back. The overview script then ran happily
        // against that page, found no course cards on it, and the tab reported
        // that the term had no classes. Pulling to refresh did it every time.
        if let homeURL {
            try await load(homeURL)
            try await waitForLeaPage()
            if try await isOnLandingPage() { return homeURL }
            // Léa mints a one-shot `Ref` into the hop, so a cached address does
            // eventually stop working. Start again from the portal.
            self.homeURL = nil
        }

        try await load(institution.portalURL)
        let href = try await string(
            #"""
            (() => {
                const link = document.querySelector(SEL.portalShortcut);
                return link ? new URL(link.getAttribute('href'), location.href).href : '';
            })();
            """#
        )
        guard let shortcut = URL(string: href), !href.isEmpty else {
            throw Failure.unavailable
        }

        try await load(shortcut)
        try await waitForLeaPage()
        let resolved = webView.url ?? shortcut
        homeURL = resolved
        return resolved
    }

    /// Forgets the hop so the next read starts from the portal again.
    func invalidate() {
        homeURL = nil
    }

    // MARK: - Reads

    func fetchOverview() async throws -> LeaOverview {
        try await exclusive {
            try await self.openHome()
            return try await self.readOverview()
        }
    }

    /// Switches Léa to another term and re-reads the landing page.
    ///
    /// Done by driving Léa's own control rather than by guessing a query
    /// parameter: the term is carried in ASP.NET view state, so a URL built by
    /// hand simply returns the current term with a new address.
    func fetchOverview(term: LeaTerm) async throws -> LeaOverview {
        try await exclusive {
        try await self.openHome()

        // Léa's own menu rows call `DoSelect` behind an unsaved-changes prompt
        // meant for teachers editing a form. Calling the function directly
        // takes the same route without raising a confirm() this app cannot
        // answer and the student never asked for.
        let changed = try await self.string(
            #"""
            (() => {
                if (typeof \#(self.conventions.termSelectFunction) !== 'function') return 'missing';
                \#(self.conventions.termSelectCall(value: term.value));
                return 'ok';
            })();
            """#
        )
        guard changed == "ok" else {
            throw Failure.unreadable(Loc.text("This term could not be selected."))
        }

        // The control posts back, so the read has to wait for the page that
        // replaces this one. A term with no classes still renders a page, so a
        // timeout here means something went wrong rather than "nothing to show".
        try await self.waitForNavigation(timeout: .seconds(20))
        try await self.waitForLeaPage()

        // What a post-back answers with is not reliably the list of classes.
        // The chosen term is held in the session either way, so if this landed
        // somewhere else, going back through Léa's front door renders it.
        if try await !self.isOnLandingPage() {
            self.homeURL = nil
            try await self.openHome()
        }
        return try await self.readOverview()
        }
    }

    private func readOverview() async throws -> LeaOverview {
        let json = try await string(overviewScript)
        guard let payload = decode(OverviewPayload.self, from: json) else {
            throw Failure.unreadable(
                Loc.text("%@ returned your classes in an unexpected format.", conventionsName)
            )
        }
        return LeaOverview(
            terms: payload.terms.map {
                LeaTerm(value: $0.value, title: $0.title, isCurrent: $0.selected)
            },
            selectedTerm: payload.terms.first(where: \.selected)?.value,
            courses: payload.courses.enumerated().map { LeaService.course(from: $1, fallbackPalette: $0) },
            isEmptyTerm: payload.courses.isEmpty,
            fetchedAt: Date()
        )
    }

    func fetchAnnouncement(at url: URL) async throws -> LeaAnnouncement {
        let json = try await read(url, announcementScript)
        guard let payload = decode(AnnouncementPayload.self, from: json) else {
            throw Failure.unreadable(Loc.text("This announcement could not be read."))
        }
        return LeaAnnouncement(
            title: payload.title,
            courseLine: payload.course.nilIfBlank,
            byline: payload.byline.nilIfBlank,
            bodyHTML: payload.body
        )
    }

    func fetchDocuments(at url: URL) async throws -> [LeaDocumentCategory] {
        let json = try await read(url, documentsScript)
        guard let payload = decode([DocumentCategoryPayload].self, from: json) else {
            throw Failure.unreadable(Loc.text("The documents could not be read."))
        }
        return payload.compactMap { category in
            let documents = category.documents.compactMap(LeaService.document(from:))
            guard !documents.isEmpty else { return nil }
            return LeaDocumentCategory(name: category.name, documents: documents)
        }
    }

    func fetchAssignments(at url: URL, for course: LeaCourse) async throws -> [LeaAssignment] {
        let json = try await readModule(
            url,
            for: course,
            kind: .assignments,
            expecting: conventions.assignmentTableSelector,
            assignmentsScript
        )
        guard let payload = decode([AssignmentPayload].self, from: json) else {
            throw Failure.unreadable(Loc.text("The assignments could not be read."))
        }
        return payload.map { item in
            LeaAssignment(
                category: item.category.nilIfBlank,
                title: item.title,
                dueText: item.due.nilIfBlank,
                dueVia: item.dueVia.nilIfBlank,
                isOverdue: item.overdue,
                hasUnreadInstructions: item.unread,
                instructionsURL: URL(string: item.instructions),
                submissionText: item.submission.nilIfBlank,
                submissionURL: URL(string: item.submissionURL),
                correctedCopyURL: URL(string: item.corrected)
            )
        }
    }

    func fetchGrades(at url: URL, for course: LeaCourse) async throws -> LeaGrades {
        let json = try await readModule(
            url,
            for: course,
            kind: .grades,
            expecting: conventions.gradeTableSelector,
            gradesScript
        )
        guard let payload = decode(GradesPayload.self, from: json) else {
            throw Failure.unreadable(Loc.text("The grades could not be read."))
        }
        return LeaGrades(
            teacher: payload.teacher.nilIfBlank,
            categories: payload.categories.map { category in
                let rule = category.rule.nilIfBlank
                return LeaGradeCategory(
                    name: category.name,
                    weightText: category.weight.nilIfBlank,
                    averageText: category.average.nilIfBlank,
                    dropRule: rule,
                    items: category.items.map {
                        LeaService.gradeItem(from: $0, inCategoryThatDropsMarks: rule != nil)
                    }
                )
            },
            summary: payload.summary.map { summary in
                LeaGradeSummary(
                    currentGrade: summary.grade.nilIfBlank,
                    currentPercent: summary.percent.nilIfBlank,
                    statistics: summary.statistics.compactMap {
                        guard !$0.label.isEmpty, !$0.value.isEmpty else { return nil }
                        return LeaGradeStatistic(label: $0.label, value: $0.value)
                    },
                    progression: payload.progression.compactMap { point in
                        guard let value = point.value, let cumulative = point.cumulative else {
                            return nil
                        }
                        return LeaGradePoint(
                            series: point.series,
                            seriesName: point.name,
                            step: point.step,
                            value: value,
                            cumulative: cumulative,
                            date: point.date.nilIfBlank
                        )
                    }
                )
            }
        )
    }

    func fetchSites(at url: URL) async throws -> [LeaSiteCategory] {
        let json = try await read(url, sitesScript)
        guard let payload = decode([SiteCategoryPayload].self, from: json) else {
            throw Failure.unreadable(Loc.text("The recommended websites could not be read."))
        }
        return payload.compactMap { category in
            let sites = category.sites.compactMap { site -> LeaSite? in
                guard let url = URL(string: site.url) else { return nil }
                return LeaSite(title: site.title, url: url, detail: site.detail.nilIfBlank)
            }
            guard !sites.isEmpty else { return nil }
            return LeaSiteCategory(name: category.name, sites: sites)
        }
    }

    /// Finds Léa's own recommended-websites page and reads the teacher list.
    ///
    /// The address is taken from Léa's navigation rather than composed: the
    /// service links carry an encrypted `Info` blob that cannot be rebuilt.
    /// Two page loads, taken as one turn.
    ///
    /// Finding the link and following it have to happen without anything else
    /// navigating in between, so this cannot be built out of two calls that
    /// each take the lock — and it cannot call the single-page reader either,
    /// which would wait for a turn this one is already holding.
    func fetchTeacherSites() async throws -> [LeaTeacherSites] {
        let json = try await exclusive { () -> String in
            try await self.openHome()
            let href = try await self.string(
                #"""
                (() => {
                    const link = document.querySelector(SEL.recommendedSitesNav);
                    return link ? new URL(link.getAttribute('href'), location.href).href : '';
                })();
                """#
            )
            guard let url = URL(string: href), !href.isEmpty else { return "" }
            try await self.load(url)
            return try await self.string(self.teacherSitesScript)
        }

        // An account whose Léa has no recommended-websites service at all, as
        // opposed to one where every teacher recommended nothing.
        guard !json.isEmpty else { return [] }

        guard let payload = decode([TeacherSitesPayload].self, from: json) else {
            throw Failure.unreadable(Loc.text("The recommended websites could not be read."))
        }
        return payload.map {
            LeaTeacherSites(teacher: $0.teacher, courseCode: $0.course, url: URL(string: $0.url))
        }
    }

    /// Cookies for the Léa host, so a download can be made with `URLSession`
    /// while still counting as the signed-in student.
    func sessionCookies() async -> [HTTPCookie] {
        await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    }

    // MARK: - Downloading a document

    /// Fetches one distributed document, freshly.
    ///
    /// The section page is re-read first rather than the stored link being used
    /// directly. Léa mints a single-use token into every document link and
    /// retires it the moment the session loads anything else — and this app
    /// loads plenty else, not least when it fetches a course's other sections
    /// ahead of time. A link that was valid when the list was drawn is usually
    /// dead by the time a student taps it, and Léa answers a dead one with its
    /// sign-out page rather than an error, which is how the app came to save
    /// HTML under a `.pdf` name and show a blank reader.
    ///
    /// Matched back by title, because the URL is exactly the part that changed.
    func downloadDocument(
        titled title: String,
        on sectionURL: URL,
        preferredName: String?
    ) async throws -> URL {
try await exclusive {
            try await self.load(sectionURL)

            let json = try await self.string(self.documentsScript)
            guard let categories = self.decode([DocumentCategoryPayload].self, from: json) else {
                throw Failure.unreadable(
                    Loc.text("%@ returned this document in an unexpected format.", self.conventionsName)
                )
            }

            let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let match = categories
                    .flatMap(\.documents)
                    .first(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == wanted }),
                let url = URL(string: match.fileURL),
                !match.fileURL.isEmpty
            else {
                throw Failure.unreadable(
                    Loc.text("%@ no longer lists this document.", self.conventionsName)
                )
            }

            return try await self.downloader.download(
                from: url,
                preferredName: preferredName ?? match.fileName.nilIfBlank ?? title,
                referer: self.webView.url ?? sectionURL
            )
        }
    }

    /// The teacher's marked-up copy of one handed-in assignment.
    ///
    /// Same one-shot token, same treatment: the list is re-read so the link is
    /// the one Léa will still honour.
    func downloadCorrectedCopy(
        forAssignmentTitled title: String,
        on sectionURL: URL
    ) async throws -> URL {
try await exclusive {
            try await self.load(sectionURL)

            let json = try await self.string(self.assignmentsScript)
            guard let assignments = self.decode([AssignmentPayload].self, from: json) else {
                throw Failure.unreadable(
                    Loc.text("%@ returned this document in an unexpected format.", self.conventionsName)
                )
            }

            let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let match = assignments.first(where: {
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
                }),
                let url = URL(string: match.corrected),
                !match.corrected.isEmpty
            else {
                throw Failure.unreadable(
                    Loc.text("%@ no longer lists this document.", self.conventionsName)
                )
            }

            return try await self.downloader.download(
                from: url,
                preferredName: title,
                referer: self.webView.url ?? sectionURL
            )
        }
    }

    // MARK: - One page at a time

    /// Léa is read through a single web view, and a web view has one address.
    ///
    /// Nothing here is a data race — the whole type is main-actor — but two
    /// reads interleaving on one address bar is a logical one, and a vicious
    /// one to debug. The second `load` replaces the first read's page while it
    /// is still being parsed, so the first read either scrapes whatever
    /// happened to arrive last or is told *"The page was replaced before it
    /// finished loading."* Opening a course did exactly this: it asked for the
    /// teacher's websites and started prefetching three sections in the same
    /// breath. It is also why a pull-to-refresh could come back claiming the
    /// term had no classes — the overview script had run against a course page.
    ///
    /// So every read takes a turn. FIFO, so a student's tap is never starved by
    /// background prefetching that was queued after it.
    private var isReading = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func exclusive<T>(_ work: () async throws -> T) async rethrows -> T {
        if isReading {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isReading = true
        }
        defer {
            if waiting.isEmpty {
                isReading = false
            } else {
                // The turn is handed straight over rather than released, so a
                // caller that arrives in between cannot jump the queue.
                waiting.removeFirst().resume()
            }
        }
        return try await work()
    }

    /// Loads a page and runs one script against it, without interruption.
    private func read(_ url: URL, _ script: String) async throws -> String {
        try await exclusive {
            try await self.load(url)
            return try await self.string(script)
        }
    }

    /// The same, for the pages that belong to one class.
    ///
    /// Léa's per-course links do not open the course — they open the *module*,
    /// and which class the module shows is held in the session rather than in
    /// the address. Follow one of them in a session that has not chosen a
    /// class and Léa renders its navigation, its class picker, and an empty
    /// body: thirty-nine tables of menu and not a single mark. That is what
    /// "No grades yet" was reporting on a course with a grade of 14.2/16.
    ///
    /// So when what was asked for is not on the page, Léa's own picker is used
    /// to choose the class and the page is read again. Only then — the class
    /// is sticky for the rest of the session, so this costs one extra load the
    /// first time a student opens a course and nothing afterwards.
    private func readModule(
        _ url: URL,
        for course: LeaCourse,
        kind: LeaSection.Kind,
        expecting selector: String,
        _ script: String
    ) async throws -> String {
        try await exclusive {
            try await self.load(url)
            if try await self.settles(on: selector) {
                return try await self.string(script)
            }

            // Nothing there. Two things can cause that and neither reports
            // itself: the address in `course` was minted when the overview was
            // fetched and Léa's links carry a one-shot `Ref`, so a spent one
            // comes back as the page's furniture with an empty body; and a
            // module can open with no class chosen, which looks identical.
            //
            // So the link is taken off the landing page as it stands now, and
            // failing that Léa's own class picker is used. Both cost a page
            // load, and neither is paid for on the ordinary path above.
            try await self.openHome()
            let fresh = try await self.string(
                self.sectionLinkScript(
                    code: course.code,
                    subtitle: course.subtitle,
                    kind: kind.rawValue
                )
            )
            let retry = URL(string: fresh) ?? url
            try await self.load(retry)

            if try await !self.settles(on: selector), try await self.selectClass(for: course) {
                try await self.load(retry)
                _ = try await self.settles(on: selector)
            }
            return try await self.string(script)
        }
    }

    /// Whether the page currently shows something matching this selector.
    private func pageContains(_ selector: String) async throws -> Bool {
        try await string(
            "(() => document.querySelector(\(selector.javascriptStringLiteral)) ? '1' : '0')()"
        ) == "1"
    }

    /// The same, given a moment to appear.
    ///
    /// "The navigation finished" is not "the page is finished". Léa fills parts
    /// of some of its screens in after the document is complete, so a read that
    /// fires the instant the load callback returns can find the chrome and none
    /// of the content — and report an empty section on a course that has one.
    private func settles(on selector: String) async throws -> Bool {
        for attempt in 0 ..< 8 {
            if try await pageContains(selector) { return true }
            if attempt < 7 { try? await Task.sleep(for: .milliseconds(350)) }
        }
        return false
    }

    /// Switches a module page to one class, by making Léa's own call.
    ///
    /// Silent when the page has no picker on it — plenty of Léa's pages do not,
    /// and the read that follows decides whether it got what it needed. Nothing
    /// is thrown for "could not choose", because a thrown error here would turn
    /// an empty section into a red failure card on pages that were never broken.
    @discardableResult
    private func selectClass(for course: LeaCourse) async throws -> Bool {
        let call = try await string(
            classSelectScript(code: course.code, subtitle: course.subtitle)
        )
        guard !call.isEmpty else { return false }

        // Called directly rather than by clicking the row, whose own handler
        // first raises an unsaved-changes prompt meant for teachers editing a
        // form — a confirm() this app cannot answer and the student never asked
        // for. Same reasoning as the term picker above.
        let made = try await string(
            #"""
            (() => {
                if (typeof \#(conventions.termSelectFunction) !== 'function') return 'missing';
                \#(call);
                return 'ok';
            })()
            """#
        )
        guard made == "ok" else { return false }

        try await waitForNavigation(timeout: .seconds(20))
        try await waitForLeaPage()
        return true
    }

    // MARK: - Navigation

    private func load(_ url: URL) async throws {
        let localized = institution.conventions.localizedPortalURL(
            url,
            languageCode: AppLanguageStore.shared.portalLanguageCode
        )
        var request = URLRequest(url: localized, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
        if let header = AppLanguageStore.shared.acceptLanguageHeader {
            request.setValue(header, forHTTPHeaderField: "Accept-Language")
        }
        webView.load(request)
        try await waitForNavigation(timeout: .seconds(30))
        try await rejectSignInWall()
    }


    private func waitForNavigation(timeout: Duration) async throws {
        // A continuation per load, and only one in flight: a second navigation
        // starting before the first finished would otherwise resume the wrong
        // caller.
        pendingNavigation?.resume(throwing: Failure.navigation(Loc.text("The page was replaced before it finished loading.")))
        pendingNavigation = nil

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failPendingNavigation()
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            pendingNavigation = continuation
        }
    }

    private func failPendingNavigation() {
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        pendingNavigation.resume(
            throwing: Failure.navigation(Loc.text("Léa took too long to answer. Check your connection and try again."))
        )
    }

    private func finishPendingNavigation(_ result: Result<Void, Error>) {
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        pendingNavigation.resume(with: result)
    }

    /// Léa answers an expired session with the portal's sign-in form rather
    /// than an error, so the form is what has to be recognised.
    private func rejectSignInWall() async throws {
        let isLogin = try await string(
            #"""
            (() => document.querySelector(\#(institution.conventions.loginFormSelector.javascriptStringLiteral)) ? '1' : '0')();
            """#
        )
        if isLogin == "1" {
            homeURL = nil
            throw Failure.sessionExpired
        }
    }

    /// Whether the web view is showing Léa's list of classes.
    ///
    /// The term menu counts as well as the course cards: a term the student
    /// took nothing in is a landing page with no cards on it, and that is an
    /// answer rather than a failed navigation.
    private func isOnLandingPage() async throws -> Bool {
        try await string(
            #"""
            (() => (
                document.querySelector(SEL.courseCard) || document.querySelector(SEL.termTable)
            ) ? '1' : '0')();
            """#
        ) == "1"
    }

    /// Léa renders in stages; the landing page is only worth reading once its
    /// own container exists.
    private func waitForLeaPage() async throws {
        for attempt in 0 ..< 12 {
            let ready = try await string(
                #"""
                (() => document.querySelector(SEL.homeReady) ? '1' : '0')();
                """#
            )
            if ready == "1" { return }
            if attempt < 11 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        // Not fatal: some Léa sub-pages have none of the landing markers. The
        // read that follows decides whether the page was usable.
    }

    // MARK: - Scripting

    private func string(_ body: String) async throws -> String {
        // The body is spliced into a `String(…)` call, so a trailing statement
        // terminator turns the whole script into a syntax error — and WebKit
        // reports that as an opaque "failed to run JavaScript", which looks
        // exactly like a page that would not answer. Trimmed here rather than
        // policed at every call site, where forgetting it costs a debugging
        // session and reads as a network problem.
        let expression = body.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t;"))
        let script = """
        (() => {
            const SEL = \(conventions.javascriptDescriptor);
            \(leaHelpers)
            const result = (\(expression));
            return typeof result === 'string' ? result : String(result);
        })();
        """

        do {
            let value = try await webView.evaluateJavaScript(script)
            return (value as? String) ?? ""
        } catch {
            throw Failure.unreadable(
                Loc.text("%@ could not be read: %@", institution.conventions.courseworkDisplayName,
                         error.localizedDescription)
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private var conventionsName: String { institution.displayName }
}

// MARK: - Navigation delegate

extension LeaService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.finishPendingNavigation(.success(())) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in self?.finishPendingNavigation(.failure(error)) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in self?.finishPendingNavigation(.failure(error)) }
    }
}

// MARK: - Mapping

private extension LeaService {
    static func course(from payload: CoursePayload, fallbackPalette: Int) -> LeaCourse {
        let sections = payload.sections.map { section in
            LeaSection(
                kind: LeaSection.Kind(rawValue: section.kind) ?? .unknown,
                label: section.label,
                trailingText: section.trailing.nilIfBlank,
                url: URL(string: section.url),
                metrics: section.metrics.map {
                    LeaMetric(
                        label: $0.label,
                        count: $0.count,
                        text: $0.text.nilIfBlank,
                        detail: $0.detail.nilIfBlank,
                        isNew: $0.isNew
                    )
                },
                announcements: section.announcements.map {
                    LeaAnnouncementSummary(
                        date: $0.date,
                        title: $0.title,
                        url: URL(string: $0.url),
                        isNew: $0.isNew
                    )
                },
                events: section.events.map {
                    LeaEventSummary(
                        date: $0.date,
                        title: $0.title,
                        detail: $0.detail.nilIfBlank,
                        url: URL(string: $0.url)
                    )
                }
            )
        }

        return LeaCourse(
            code: payload.code,
            title: payload.title,
            subtitle: payload.subtitle,
            teacher: payload.teacher.nilIfBlank,
            paletteIndex: payload.palette > 0 ? payload.palette : fallbackPalette + 1,
            sections: sections
        )
    }

    static func document(from payload: DocumentPayload) -> LeaDocument? {
        let destination: LeaDocument.Destination
        if let external = URL(string: payload.externalURL), !payload.externalURL.isEmpty {
            destination = .externalLink(external)
        } else if let file = URL(string: payload.fileURL), !payload.fileURL.isEmpty {
            destination = .file(
                name: payload.fileName.nilIfBlank,
                size: payload.fileSize.nilIfBlank,
                url: file
            )
        } else {
            return nil
        }

        return LeaDocument(
            title: payload.title,
            detail: payload.detail.nilIfBlank,
            requiredBy: payload.requiredBy.nilIfBlank,
            availableSince: payload.since.nilIfBlank,
            isUnread: payload.unread,
            destination: destination
        )
    }

    /// - Parameter inCategoryThatDropsMarks: whether the category this row sits
    ///   in announced a drop rule. Léa says a mark is dropped twice over — in a
    ///   sentence under its title, and by greying the row — and the two are not
    ///   trusted equally. The sentence is Léa saying so, so it stands on its
    ///   own. Grey is a colour, and only means "dropped" where dropping is
    ///   happening; believed anywhere else it would tell a student a mark does
    ///   not count when it does, which is worse than saying nothing at all.
    static func gradeItem(
        from payload: GradeItemPayload,
        inCategoryThatDropsMarks: Bool
    ) -> LeaGradeItem {
        let note = payload.discardNote.nilIfBlank
        return LeaGradeItem(
            position: payload.position.nilIfBlank,
            title: payload.title,
            date: payload.date.nilIfBlank,
            mark: payload.mark.nilIfBlank,
            markPercent: payload.markPercent.nilIfBlank,
            classAverage: payload.classAverage.nilIfBlank,
            weight: payload.weight.nilIfBlank,
            weightPoints: payload.weightPoints.nilIfBlank,
            isDiscarded: note != nil || (payload.muted && inCategoryThatDropsMarks),
            discardNote: note,
            comment: payload.commentBody.nilIfBlank.map {
                LeaGradeComment(heading: payload.commentHeading, body: $0)
            }
        )
    }
}

// MARK: - Wire shapes
//
// Deliberately flat and all-strings: the page prints text, and a decoder that
// insists on richer types fails the whole read because one teacher typed a
// grade Léa did not expect.

private struct OverviewPayload: Decodable {
    struct Term: Decodable {
        let value: String
        let title: String
        let selected: Bool
    }
    let terms: [Term]
    let courses: [CoursePayload]
}

private struct CoursePayload: Decodable {
    let code: String
    let title: String
    let subtitle: String
    let teacher: String
    let palette: Int
    let sections: [SectionPayload]
}

private struct SectionPayload: Decodable {
    struct Metric: Decodable {
        let label: String
        let count: Int?
        let text: String
        let detail: String
        let isNew: Bool
    }
    struct Announcement: Decodable {
        let date: String
        let title: String
        let url: String
        let isNew: Bool
    }
    struct Event: Decodable {
        let date: String
        let title: String
        let detail: String
        let url: String
    }

    let kind: String
    let label: String
    let trailing: String
    let url: String
    let metrics: [Metric]
    let announcements: [Announcement]
    let events: [Event]
}

private struct AnnouncementPayload: Decodable {
    let title: String
    let course: String
    let byline: String
    let body: String
}

private struct DocumentCategoryPayload: Decodable {
    let name: String
    let documents: [DocumentPayload]
}

private struct DocumentPayload: Decodable {
    let title: String
    let detail: String
    let requiredBy: String
    let since: String
    let unread: Bool
    let fileURL: String
    let fileName: String
    let fileSize: String
    let externalURL: String
}

private struct AssignmentPayload: Decodable {
    let category: String
    let title: String
    let due: String
    let dueVia: String
    let overdue: Bool
    let unread: Bool
    let instructions: String
    let submission: String
    let submissionURL: String
    let corrected: String
}

private struct GradesPayload: Decodable {
    struct Category: Decodable {
        let name: String
        /// "The 4 lowest results in this category will be discarded.", when
        /// the teacher drops marks and Léa says so at the top of the category.
        let rule: String
        let weight: String
        let average: String
        let items: [GradeItemPayload]
    }
    struct Statistic: Decodable {
        let label: String
        let value: String
    }
    struct Summary: Decodable {
        let grade: String
        let percent: String
        let statistics: [Statistic]
    }
    /// One point read out of the progression graph's tooltips. The numbers are
    /// optional because a point Léa has plotted but not labelled is a point
    /// with no value to draw.
    struct Point: Decodable {
        let series: Int
        let name: String
        let step: Int
        let value: Double?
        let cumulative: Double?
        let date: String
    }
    let teacher: String
    let categories: [Category]
    let summary: Summary?
    let progression: [Point]
}

private struct GradeItemPayload: Decodable {
    let position: String
    let title: String
    let date: String
    /// Léa's own sentence saying this mark will be dropped, when it printed one.
    let discardNote: String
    /// Whether Léa greyed the row out. What that means is decided in Swift.
    let muted: Bool
    let mark: String
    let markPercent: String
    let classAverage: String
    let weight: String
    let weightPoints: String
    let commentHeading: String
    let commentBody: String
}

private struct SiteCategoryPayload: Decodable {
    struct Site: Decodable {
        let title: String
        let url: String
        let detail: String
    }
    let name: String
    let sites: [Site]
}

private struct TeacherSitesPayload: Decodable {
    let teacher: String
    let course: String
    let url: String
}

// MARK: - Small helpers

extension String {
    /// Empty and whitespace-only both mean "the page printed nothing here".
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// This value as a JavaScript string literal, quotes and all.
    ///
    /// Built by the JSON encoder rather than by hand: a course title with an
    /// apostrophe in it is ordinary, and hand-escaping is how injected scripts
    /// come to have syntax errors on exactly the pages that matter.
    var javascriptStringLiteral: String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [self], options: []),
            let json = String(data: data, encoding: .utf8),
            json.count >= 2
        else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }
}

extension Array where Element == String {
    /// These values as a JavaScript array literal, escaped the same way.
    var javascriptArrayLiteral: String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: self, options: []),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }
}
