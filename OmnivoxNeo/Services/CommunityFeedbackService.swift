import Combine
import Foundation

/// Reads the public roadmap from GitHub.
///
/// Three things shape this. There is **no token** — it talks to the public
/// issues endpoint anonymously, because an API key shipped inside an app is a
/// published API key, and a roadmap that needs a GitHub account to read is not
/// a public roadmap. There is **no account**: a student never signs in to
/// anything here. And it is **completely separate from the portal session** —
/// its own `URLSession`, no cookies, nothing about the student on the wire. The
/// request this makes is indistinguishable from any other anonymous reader's.
///
/// What anonymous costs is sixty requests an hour from one address, which is
/// why the answer is cached on disk and refreshed on a schedule rather than on
/// every appearance.
@MainActor
final class CommunityFeedbackService: ObservableObject {
    /// Which repository holds the roadmap.
    ///
    /// The app's own repository: the issues people file and the code they are
    /// filed against are the same project, so an issue can be closed by a
    /// commit that references it.
    static let repository = "Thomas20090425/OmnivoxNeo"

    /// The feedback form, as a published page.
    ///
    /// Served from GitHub Pages out of the repository's `docs/` folder, which
    /// is where the licence and the privacy policy are published from too.
    ///
    /// - Important: Pages for this repository is currently configured to serve
    ///   from the branch root rather than from `docs/`, which is why `docs` is
    ///   in the path. If that setting is ever changed to `/docs`, this line is
    ///   the only one that needs editing.
    static let feedbackPageURL = URL(
        string: "https://thomas20090425.github.io/OmnivoxNeo/docs/feedback.html"
    )!

    /// The roadmap in a browser, for anybody who would rather read it there.
    static var repositoryIssuesURL: URL {
        URL(string: "https://github.com/\(repository)/issues")!
    }

    /// How stale a cached copy may be before a fresh look is taken. Well
    /// inside the anonymous rate limit even if somebody opens the screen
    /// repeatedly, and short enough that a status change shows up the same day.
    static let refreshInterval: TimeInterval = 15 * 60

    /// A ceiling on paging. Five hundred items is far more roadmap than this
    /// project will have, and an unbounded loop driven by a `Link` header from
    /// the network is not something to leave running on a phone.
    private static let maximumPages = 5

    // MARK: - What the screen reads

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// Something went wrong and there is nothing cached to fall back on.
        case failed(CommunityFeedbackError)
    }

    @Published private(set) var issues: [CommunityIssue] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var lastUpdated: Date?
    /// Set when a refresh failed but a cached copy is still being shown, so the
    /// screen can say the list might be out of date instead of pretending.
    @Published private(set) var staleWarning: CommunityFeedbackError?
    /// Set when paging stopped at the ceiling, so the screen can say so rather
    /// than quietly showing a truncated roadmap.
    @Published private(set) var didTruncate = false

    private let session: URLSession
    private let cache: CommunityIssueCache
    private var inFlight: Task<Void, Never>?

    init(cache: CommunityIssueCache = CommunityIssueCache()) {
        self.cache = cache

        // Its own session, configured to carry nothing. The college session's
        // cookies live in a `WKWebsiteDataStore` and never touch `URLSession`,
        // but saying so in code is better than relying on it.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 40
        // The disk cache is this app's own, written below. Letting URLSession
        // keep a second copy would mean two answers and no way to tell which
        // one is on screen.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)

        if let snapshot = cache.load() {
            issues = snapshot.issues
            lastUpdated = snapshot.fetchedAt
            state = .loaded
        }
    }

    // MARK: - Loading

    /// Called when the screen appears. Shows whatever is cached immediately and
    /// goes to the network only if that copy is old.
    func loadIfNeeded() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.refreshInterval,
           !issues.isEmpty {
            return
        }
        refresh()
    }

    /// Pull to refresh, and the button on an error screen. Always goes out.
    func refresh() {
        inFlight?.cancel()
        inFlight = Task { await performRefresh() }
    }

    /// The `async` form, so `.refreshable` can hold its spinner until the work
    /// is actually finished.
    func refreshAndWait() async {
        inFlight?.cancel()
        let task = Task { await performRefresh() }
        inFlight = task
        await task.value
    }

    /// Keeps refreshing until a just-filed report actually turns up.
    ///
    /// GitHub creates the issue immediately but its list endpoint can answer
    /// without it for a second or two afterwards, so a single refresh on
    /// closing the form often comes back exactly as it was. From the other
    /// side of the screen that is indistinguishable from the report having
    /// gone nowhere — which is the one thing this whole screen exists to
    /// disprove. So it asks again, a few times, for the one number it is
    /// waiting for, and gives up quietly rather than spinning forever.
    func refreshUntilPresent(issue number: Int) async {
        let waits: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(3), .seconds(5)]
        for wait in waits {
            if wait != .zero {
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
            await refreshAndWait()
            if issues.contains(where: { $0.number == number }) { return }
        }
    }

    private func performRefresh() async {
        if issues.isEmpty { state = .loading }
        staleWarning = nil

        do {
            let (fetched, truncated) = try await fetchAllPages()
            guard !Task.isCancelled else { return }
            let sorted = fetched.sorted { $0.updatedAt > $1.updatedAt }
            issues = sorted
            didTruncate = truncated
            lastUpdated = Date()
            state = .loaded
            cache.save(CommunityIssueSnapshot(fetchedAt: Date(), issues: sorted))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let failure = CommunityFeedbackError.from(error)
            // A failed refresh does not throw away a good list. Showing
            // yesterday's roadmap with a note saying so beats showing an error
            // page instead of information the student already had.
            if issues.isEmpty {
                state = .failed(failure)
            } else {
                state = .loaded
                staleWarning = failure
            }
        }
    }

    private func fetchAllPages() async throws -> (issues: [CommunityIssue], truncated: Bool) {
        var collected: [CommunityIssue] = []
        var next: URL? = Self.firstPageURL
        var page = 0

        while let url = next {
            try Task.checkCancellation()
            let result = try await fetchPage(url)
            collected.append(contentsOf: result.issues)
            next = result.nextPageURL
            page += 1
            if page >= Self.maximumPages, next != nil {
                return (collected, true)
            }
        }
        return (collected, false)
    }

    private static var firstPageURL: URL {
        var components = URLComponents(
            string: "https://api.github.com/repos/\(repository)/issues"
        )!
        components.queryItems = [
            URLQueryItem(name: "state", value: "all"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc")
        ]
        return components.url!
    }

    private func fetchPage(_ url: URL) async throws -> CommunityIssuePage {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw CommunityFeedbackError.unreachable
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 403, 429:
            // GitHub answers 403 both for "too many requests from your
            // address" and for "you may not read this". They need different
            // words, and the remaining-requests header is what tells them
            // apart.
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            if remaining == "0" {
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset")
                    .flatMap(Double.init)
                    .map { Date(timeIntervalSince1970: $0) }
                throw CommunityFeedbackError.rateLimited(until: reset)
            }
            throw CommunityFeedbackError.serverRefused(status: http.statusCode)
        case 404:
            throw CommunityFeedbackError.notFound
        default:
            throw CommunityFeedbackError.serverRefused(status: http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payloads: [GitHubIssuePayload]
        do {
            payloads = try decoder.decode([GitHubIssuePayload].self, from: data)
        } catch {
            throw CommunityFeedbackError.unreadable
        }

        return CommunityIssuePage(
            // Pull requests are dropped here, by the initializer that returns
            // nil for them.
            issues: payloads.compactMap(CommunityIssue.init(payload:)),
            nextPageURL: CommunityIssuePage.nextPageURL(
                fromLinkHeader: http.value(forHTTPHeaderField: "Link")
            )
        )
    }

    // MARK: - Grouping, for the screen

    /// The issues matching a filter, under their headings, in display order.
    /// Empty groups are left out rather than shown empty.
    func groups(matching filter: CommunityIssueFilter) -> [(
        group: CommunityIssueGroup, issues: [CommunityIssue]
    )] {
        let matching = issues.filter(filter.accepts)
        return CommunityIssueGroup.displayOrder.compactMap { group in
            let items = matching.filter { $0.status.group == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    func count(matching filter: CommunityIssueFilter) -> Int {
        issues.filter(filter.accepts).count
    }

    /// Forgets the cached roadmap.
    ///
    /// Wired to the same switch that controls everything else kept on the
    /// device. A list of public issue titles is not sensitive, but "keeps
    /// nothing on this device" has to mean nothing.
    func clearCache() {
        cache.clear()
        issues = []
        lastUpdated = nil
        state = .idle
    }
}

// MARK: - What can go wrong

/// Why the roadmap could not be read, in words that say what to do about it.
enum CommunityFeedbackError: Error, Equatable, Hashable {
    case unreachable
    case rateLimited(until: Date?)
    case notFound
    case serverRefused(status: Int)
    case unreadable

    static func from(_ error: Error) -> Self {
        if let known = error as? CommunityFeedbackError { return known }
        let code = (error as NSError)
        if code.domain == NSURLErrorDomain { return .unreachable }
        return .unreadable
    }

    /// Localized here rather than by the view, because the messages below take
    /// arguments — a reset time, a status code — and a key with a placeholder
    /// in it cannot be looked up from an already-interpolated string.
    @MainActor
    var title: String {
        switch self {
        case .unreachable: Loc.text("No Connection")
        case .rateLimited: Loc.text("Too Many Requests")
        case .notFound: Loc.text("Roadmap Not Found")
        case .serverRefused: Loc.text("GitHub Could Not Answer")
        case .unreadable: Loc.text("Unexpected Answer")
        }
    }

    var systemImage: String {
        switch self {
        case .unreachable: "wifi.slash"
        case .rateLimited: "hourglass"
        case .notFound: "questionmark.folder"
        case .serverRefused, .unreadable: "exclamationmark.triangle"
        }
    }

    @MainActor
    var message: String {
        switch self {
        case .unreachable:
            return Loc.text("The roadmap is read from GitHub, so it needs a connection. Everything else in the app still works without one.")
        case .rateLimited(let until):
            guard let until else {
                return Loc.text("GitHub limits how often it will answer without an account, and this device has reached that limit. Try again shortly.")
            }
            return Loc.text(
                "GitHub limits how often it will answer without an account, and this device has reached that limit. It resets at %@.",
                until.formatted(date: .omitted, time: .shortened)
            )
        case .notFound:
            return Loc.text("The repository holding the roadmap could not be found. It may have been renamed.")
        case .serverRefused(let status):
            return Loc.text("GitHub answered with an error (%@). This is usually temporary.", "\(status)")
        case .unreadable:
            return Loc.text("GitHub's answer could not be read. This usually means the app needs an update.")
        }
    }
}

// MARK: - Keeping a copy

struct CommunityIssueSnapshot: Codable, Sendable {
    static let currentContentVersion = 1

    let fetchedAt: Date
    let issues: [CommunityIssue]
    var contentVersion: Int? = CommunityIssueSnapshot.currentContentVersion
}

/// The roadmap, saved so the screen opens with something on it.
///
/// Not scoped to a profile and not protected behind the lock, unlike the
/// schedule cache — this is a list of public issue titles that anybody can read
/// on github.com, and it says nothing about who the student is. It is kept out
/// of iCloud backups all the same, because it is a cache and restoring a stale
/// cache onto a new phone has no value.
struct CommunityIssueCache: Sendable {
    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Community", isDirectory: true)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent("roadmap.json")
    }

    func load() -> CommunityIssueSnapshot? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let snapshot = try? decoder.decode(CommunityIssueSnapshot.self, from: data),
            snapshot.contentVersion == CommunityIssueSnapshot.currentContentVersion
        else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: CommunityIssueSnapshot) {
        do {
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = directoryURL
            try? directory.setResourceValues(values)
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // A cache that cannot be written is a slower screen, not a broken
            // one. The list on screen is already correct.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
