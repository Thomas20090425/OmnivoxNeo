import Combine
import Foundation
import WebKit

/// Something fetched from Léa, and what is currently true about it.
///
/// Four states rather than an optional plus a flag: "never asked", "asking" and
/// "asked and it failed" are different screens, and collapsing them is how a
/// spinner ends up spinning forever over an error nobody printed.
enum LeaLoadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Everything the Léa screens read from, and the only thing that talks to
/// `LeaService`.
///
/// Fetches are lazy and cached per course: the landing page already says how
/// many documents and assignments each course has, so opening the tab costs one
/// page load, and only the section a student actually taps costs another.
@MainActor
final class LeaStore: ObservableObject {
    @Published private(set) var overview: LeaLoadable<LeaOverview> = .idle
    @Published private(set) var selectedTerm: LeaTerm?
    @Published private(set) var isSwitchingTerm = false

    @Published private(set) var documents: [String: LeaLoadable<[LeaDocumentCategory]>] = [:]
    @Published private(set) var assignments: [String: LeaLoadable<[LeaAssignment]>] = [:]
    @Published private(set) var grades: [String: LeaLoadable<LeaGrades>] = [:]
    @Published private(set) var announcements: [String: LeaLoadable<LeaAnnouncement>] = [:]
    @Published private(set) var teacherSites: LeaLoadable<[LeaTeacherSites]> = .idle
    @Published private(set) var sites: [String: LeaLoadable<[LeaSiteCategory]>] = [:]

    /// Documents the student has opened in this app since the last refresh.
    ///
    /// Léa clears its own star server-side when the file is fetched, but the
    /// landing page in memory still says otherwise until the next refresh, so
    /// the star is cleared here too rather than lying until then.
    @Published private(set) var locallyRead: Set<String> = []

    private let institution: Institution
    private let service: LeaService
    private var inFlight: Set<String> = []

    /// Proper course names, by course code.
    ///
    /// Léa shouts its titles in capitals and then clips them to fit its own
    /// card — `CALCULUS I: DIFFERENTIAL CALCULUS FOR SOCIAL...` is all it will
    /// say. The timetable the app already scrapes has the whole name, cased the
    /// way the registrar wrote it, so that is preferred wherever it matches.
    @Published var knownCourseTitles: [String: String] = [:]

    /// How far the file currently downloading has got, 0…1.
    ///
    /// Nil when nothing is downloading, and also when the server declined to
    /// say how big the file is — the row falls back to an indeterminate bar
    /// rather than to a bar that sits at zero and looks stuck.
    @Published private(set) var downloadProgress: Double?

    init(institution: Institution, websiteDataStore: WKWebsiteDataStore) {
        self.institution = institution
        service = LeaService(institution: institution, websiteDataStore: websiteDataStore)
        service.onDownloadProgress = { [weak self] fraction in
            self?.downloadProgress = fraction
        }
    }

    /// The best name the app has for a course.
    func displayTitle(for course: LeaCourse) -> String {
        if let code = Self.courseCode(in: course.code),
           let known = knownCourseTitles[code],
           !known.isEmpty {
            return known.sentenceCasedCourseTitle
        }
        return course.title.sentenceCasedCourseTitle
    }

    /// What this course looks like: its symbol, colour and subject.
    func identity(for course: LeaCourse) -> CourseIdentity {
        CourseIdentity.forCourse(code: course.code, title: displayTitle(for: course))
    }

    /// Adopts the timetable's course names. Called with whatever the schedule
    /// scrape produced; codes Léa does not use are simply never looked up.
    func adoptCourseTitles(_ pairs: [(label: String, title: String)]) {
        var titles: [String: String] = [:]
        for pair in pairs {
            guard
                let code = Self.courseCode(in: pair.label),
                case let title = pair.title.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
            else { continue }
            // First one wins: the same course appears once per weekly meeting,
            // and they all carry the same name.
            if titles[code] == nil { titles[code] = title }
        }
        guard titles != knownCourseTitles else { return }
        knownCourseTitles = titles
    }

    /// The ministry code inside a label, which may carry a section after it.
    ///
    /// `345-101-MQ sect. 00007` and `345-101-MQ` have to reach the same entry,
    /// because Léa writes one and the timetable writes the other.
    private static func courseCode(in label: String) -> String? {
        let upper = label.uppercased()
        guard
            let match = upper.firstMatch(of: /[0-9]{3}-[0-9A-Z]{2,4}-[0-9A-Z]{2,3}/)
        else {
            let trimmed = upper.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(match.output)
    }

    // MARK: - Term overview

    var courses: [LeaCourse] { overview.value?.courses ?? [] }
    var terms: [LeaTerm] { overview.value?.terms ?? [] }

    /// How many things across every course are waiting to be looked at.
    var unreadCount: Int {
        courses.reduce(0) { $0 + $1.unreadCount }
    }

    func loadIfNeeded() {
        guard case .idle = overview else { return }
        refresh()
    }

    func refresh() {
        guard !inFlight.contains("overview") else { return }
        inFlight.insert("overview")
        overview = .loading
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove("overview") }
            do {
                let result = try await service.fetchOverview()
                apply(result)
            } catch {
                overview = .failed(Self.describe(error))
            }
        }
    }

    func select(term: LeaTerm) {
        guard term.value != selectedTerm?.value, !isSwitchingTerm else { return }
        isSwitchingTerm = true
        selectedTerm = term
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSwitchingTerm = false }
            do {
                let result = try await service.fetchOverview(term: term)
                apply(result)
            } catch {
                overview = .failed(Self.describe(error))
            }
        }
    }

    private func apply(_ result: LeaOverview) {
        overview = .loaded(result)
        if let current = result.terms.first(where: { $0.value == result.selectedTerm }) {
            selectedTerm = current
        } else if selectedTerm == nil {
            selectedTerm = result.terms.first
        }
        // A new term is a different set of courses; anything cached under the
        // old one would be shown beside the wrong course code.
        documents.removeAll()
        assignments.removeAll()
        grades.removeAll()
        announcements.removeAll()
        sites.removeAll()
        locallyRead.removeAll()
    }

    // MARK: - Sections

    func loadDocuments(for course: LeaCourse) {
        load(
            key: course.id,
            url: course.section(.documents)?.url,
            state: \.documents,
            fetch: { try await self.service.fetchDocuments(at: $0) }
        )
    }

    func loadAssignments(for course: LeaCourse) {
        load(
            key: course.id,
            url: course.section(.assignments)?.url,
            state: \.assignments,
            fetch: { try await self.service.fetchAssignments(at: $0, for: course) }
        )
    }

    func loadGrades(for course: LeaCourse) {
        load(
            key: course.id,
            url: course.section(.grades)?.url,
            state: \.grades,
            fetch: { try await self.service.fetchGrades(at: $0, for: course) }
        )
    }

    func loadAnnouncement(at url: URL) {
        load(
            key: url.absoluteString,
            url: url,
            state: \.announcements,
            fetch: { try await self.service.fetchAnnouncement(at: $0) }
        )
    }

    func loadTeacherSites() {
        guard case .idle = teacherSites, !inFlight.contains("sites") else { return }
        inFlight.insert("sites")
        teacherSites = .loading
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove("sites") }
            do {
                teacherSites = .loaded(try await service.fetchTeacherSites())
            } catch {
                teacherSites = .failed(Self.describe(error))
            }
        }
    }

    /// The recommended-sites entry that belongs to a course.
    ///
    /// Matched on the course code rather than the teacher's name: a teacher can
    /// hold two sections and a course can change hands, but the code on the
    /// sites table is the same string Léa prints on the course card.
    func sites(forCourseCode code: String) -> LeaTeacherSites? {
        let wanted = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return teacherSites.value?.first {
            $0.courseCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
    }

    func loadSites(for teacher: LeaTeacherSites) {
        load(
            key: teacher.id,
            url: teacher.url,
            state: \.sites,
            fetch: { try await self.service.fetchSites(at: $0) }
        )
    }

    func reloadDocuments(for course: LeaCourse) {
        documents[course.id] = nil
        loadDocuments(for: course)
    }

    func reloadAssignments(for course: LeaCourse) {
        assignments[course.id] = nil
        loadAssignments(for: course)
    }

    func reloadGrades(for course: LeaCourse) {
        grades[course.id] = nil
        loadGrades(for: course)
    }

    /// Starts fetching a course's sections before the student asks for them.
    ///
    /// Léa is read through one web view, one page at a time, so these cannot
    /// overlap — asking for three at once would have them trample each other's
    /// navigation. They are queued instead, in the order a student is most
    /// likely to want them, and each screen shows whatever has arrived. By the
    /// time a section is tapped it is usually already there, which is most of
    /// what made the old screens feel slow: nothing started until the tap.
    func prefetch(for course: LeaCourse) {
        let key = "prefetch-\(course.id)"
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(key) }

            for step in [LeaSection.Kind.grades, .documents, .assignments] {
                guard course.section(step) != nil else { continue }
                switch step {
                case .grades: loadGrades(for: course)
                case .documents: loadDocuments(for: course)
                case .assignments: loadAssignments(for: course)
                default: break
                }
                // Let the one in flight finish before queueing the next, so the
                // section the student is looking at is never held up behind a
                // background fetch of one they are not.
                await settle(course: course, kind: step)
            }
        }
    }

    /// Waits until a section has stopped loading, however it ended.
    private func settle(course: LeaCourse, kind: LeaSection.Kind) async {
        for _ in 0 ..< 200 {
            let isLoading: Bool = switch kind {
            case .grades: grades[course.id]?.isLoading ?? false
            case .documents: documents[course.id]?.isLoading ?? false
            case .assignments: assignments[course.id]?.isLoading ?? false
            default: false
            }
            if !isLoading { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// One shape for every section fetch: same de-duplication, same error text,
    /// same "the page had no link so there is nothing to fetch" answer.
    private func load<Value>(
        key: String,
        url: URL?,
        state: ReferenceWritableKeyPath<LeaStore, [String: LeaLoadable<Value>]>,
        fetch: @escaping (URL) async throws -> Value
    ) {
        let token = "\(state.hashValue)-\(key)"
        guard !inFlight.contains(token) else { return }
        if case .loaded = self[keyPath: state][key] { return }

        guard let url else {
            self[keyPath: state][key] = .failed(
                Loc.text("%@ did not publish this section for this course.", institution.conventions.courseworkDisplayName)
            )
            return
        }

        inFlight.insert(token)
        self[keyPath: state][key] = .loading
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(token) }
            do {
                self[keyPath: state][key] = .loaded(try await fetch(url))
            } catch {
                self[keyPath: state][key] = .failed(Self.describe(error))
            }
        }
    }

    // MARK: - Reading a document

    /// Downloads a Léa-hosted file and, in doing so, tells Léa it was read.
    ///
    /// The same URL that serves the bytes is the one that clears the star, so
    /// there is no separate "mark as read" call to make — and no way to read a
    /// document without Léa finding out, which is the portal's own behaviour.
    func download(_ document: LeaDocument, from page: URL? = nil) async throws -> URL {
        guard case .file(let name, _, _) = document.destination else {
            throw LeaService.Failure.unreadable(Loc.text("This item is a link, not a file."))
        }
        guard let page else {
            throw LeaService.Failure.unreadable(
                Loc.text("%@ did not say where this document lives.",
                         institution.conventions.courseworkDisplayName)
            )
        }

        defer { downloadProgress = nil }
        let destination = try await service.downloadDocument(
            titled: document.title,
            on: page,
            preferredName: name
        )

        // Léa answers an expired session with a perfectly ordinary 200 whose
        // body is a sign-in page, so "did the download succeed" has to be asked
        // of the bytes rather than of the status code. Silence here is what
        // used to reach the reader as a blank document.
        if let problem = rejection(at: destination) {
            try? FileManager.default.removeItem(at: destination)
            throw LeaService.Failure.unreadable(problem)
        }

        markRead(document)
        return destination
    }

    /// The teacher's marked-up copy of an assignment, read in the app.
    func downloadCorrectedCopy(for assignment: LeaAssignment, in course: LeaCourse) async throws -> URL {
        guard let page = course.section(.assignments)?.url else {
            throw LeaService.Failure.unreadable(
                Loc.text("%@ did not say where this document lives.",
                         institution.conventions.courseworkDisplayName)
            )
        }

        defer { downloadProgress = nil }
        let destination = try await service.downloadCorrectedCopy(
            forAssignmentTitled: assignment.title,
            on: page
        )
        if let problem = rejection(at: destination) {
            try? FileManager.default.removeItem(at: destination)
            throw LeaService.Failure.unreadable(problem)
        }
        return destination
    }

    /// Why a downloaded file is not the document it claims to be, if it isn't.
    private func rejection(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Loc.text("The download could not be saved.")
        }
        defer { try? handle.close() }

        let head = (try? handle.read(upToCount: 1_024)) ?? Data()
        guard !head.isEmpty else {
            return Loc.text("The download was empty.")
        }

        let extensions = ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "zip"]
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }

        // A document of any of those types starts with a signature. HTML where
        // one of those belongs means Léa answered with a page, not a file.
        let text = String(decoding: head, as: UTF8.self).lowercased()
        let looksLikeHTML = text.contains("<html") || text.contains("<!doctype html")
        guard looksLikeHTML else { return nil }

        return Loc.text(
            "Your %@ session has expired. Pull down to refresh, then open it again.",
            institution.conventions.courseworkDisplayName
        )
    }

    func markRead(_ document: LeaDocument) {
        guard document.isUnread, !locallyRead.contains(document.id) else { return }
        locallyRead.insert(document.id)
    }

    func isUnread(_ document: LeaDocument) -> Bool {
        document.isUnread && !locallyRead.contains(document.id)
    }

    /// Cookies for a URL the app hands to a web view rather than fetching
    /// itself, so the submission page opens signed in.
    func sessionCookies() async -> [HTTPCookie] {
        await service.sessionCookies()
    }

    // MARK: - Helpers

    private static func safeFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "document" : cleaned
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? LeaService.Failure { return failure.message }
        return error.localizedDescription
    }
}
