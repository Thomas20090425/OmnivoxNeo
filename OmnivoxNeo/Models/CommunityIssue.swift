import Foundation

/// One item on the public roadmap — a reported bug or a requested feature.
///
/// There is no database behind this and there is not going to be one. The
/// GitHub issues of the app's own repository *are* the roadmap: anybody can
/// read them in a browser, the history is public, and nothing here can show a
/// student something different from what is actually recorded. That is the
/// whole reason for picking GitHub over a backend — not that it is free, but
/// that it is checkable.
struct CommunityIssue: Identifiable, Hashable, Codable, Sendable {
    let number: Int
    let title: String
    /// Just the reporter's own words, lifted out of the issue body. See
    /// `CommunityIssue.description(fromIssueBody:)`.
    let summary: String?
    let status: CommunityIssueStatus
    let category: CommunityIssueCategory
    /// The name the reporter chose to put on it, if they chose to.
    let attribution: String?
    let labels: [String]
    let updatedAt: Date
    let createdAt: Date
    let commentCount: Int
    /// The issue on github.com, for reading the full thread.
    let webURL: URL?

    var id: Int { number }
}

// MARK: - Status

/// Where an item has got to.
///
/// Read off the issue's own state and labels rather than written down
/// anywhere, so moving an item along is a label change on GitHub and the app
/// follows. The one rule worth stating out loud: a closed issue with no stated
/// reason reads as `closed`, never as `completed`. Telling somebody their bug
/// was fixed when all that is known is that the issue was closed would be the
/// app inventing good news.
enum CommunityIssueStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case underReview
    case planned
    case inProgress
    case completed
    case notPlanned
    case duplicate
    /// Closed, with nothing recorded about why.
    case closed

    /// The labels that move an item along, in the order they are checked.
    ///
    /// Several spellings are accepted for each because the label set is edited
    /// by hand on a website at speed; `in-progress` and `in progress` meaning
    /// different things would be a trap, not a feature.
    private static let plannedLabels = ["status:planned", "status: planned", "planned", "roadmap"]
    private static let inProgressLabels = [
        "status:in-progress", "status: in-progress", "status:in progress",
        "in-progress", "in progress", "wip"
    ]

    /// Works out the status of a GitHub issue.
    ///
    /// - Parameters:
    ///   - isOpen: whether GitHub reports the issue as open.
    ///   - stateReason: GitHub's own `state_reason` — `completed`,
    ///     `not_planned`, `duplicate`, `reopened`, or nothing at all.
    ///   - labels: the issue's labels, in any case.
    static func resolve(isOpen: Bool, stateReason: String?, labels: [String]) -> Self {
        let lowered = Set(labels.map { $0.lowercased() })

        if isOpen {
            // A label beats no label; in-progress beats planned, because
            // something being worked on is the more specific claim.
            if inProgressLabels.contains(where: lowered.contains) { return .inProgress }
            if plannedLabels.contains(where: lowered.contains) { return .planned }
            return .underReview
        }

        // Closed. GitHub's reason is the authority when there is one; a label
        // is the fallback, since `duplicate` and `wontfix` predate
        // `state_reason` and plenty of issues carry only those.
        switch stateReason?.lowercased() {
        case "completed": return .completed
        case "duplicate": return .duplicate
        case "not_planned": return lowered.contains("duplicate") ? .duplicate : .notPlanned
        default: break
        }
        if lowered.contains("duplicate") { return .duplicate }
        if lowered.contains("wontfix") || lowered.contains("invalid") { return .notPlanned }
        return .closed
    }

    /// Which heading an item appears under.
    var group: CommunityIssueGroup {
        switch self {
        case .underReview: .underReview
        case .planned: .planned
        case .inProgress: .inProgress
        case .completed: .completed
        case .notPlanned, .duplicate, .closed: .closedOut
        }
    }

    /// The words shown on the item itself, which are not always the words on
    /// the heading above it — a `closed` item sits under "Not Planned or
    /// Closed" but says only "Closed", because that is all that is known.
    var label: String {
        switch self {
        case .underReview: "Under Review"
        case .planned: "Planned"
        case .inProgress: "In Progress"
        case .completed: "Completed"
        case .notPlanned: "Not Planned"
        case .duplicate: "Duplicate"
        case .closed: "Closed"
        }
    }

    var systemImage: String {
        switch self {
        case .underReview: "tray"
        case .planned: "calendar"
        case .inProgress: "hammer"
        case .completed: "checkmark.circle"
        case .notPlanned: "slash.circle"
        case .duplicate: "square.on.square"
        case .closed: "archivebox"
        }
    }
}

/// The five headings the roadmap is divided into.
///
/// Finished work is kept apart from live work deliberately: somebody opening
/// this screen wants to know whether their problem is known and whether
/// anything is happening about it, and a long list of things already fixed
/// buries that.
enum CommunityIssueGroup: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case underReview
    case planned
    case inProgress
    case completed
    case closedOut

    var id: String { rawValue }

    /// The order they appear in: what is being worked on, then what will be,
    /// then what was, then what will not be.
    static let displayOrder: [Self] = [.inProgress, .planned, .underReview, .completed, .closedOut]

    var title: String {
        switch self {
        case .underReview: "Under Review"
        case .planned: "Planned"
        case .inProgress: "In Progress"
        case .completed: "Completed"
        case .closedOut: "Not Planned or Closed"
        }
    }

    var explanation: String {
        switch self {
        case .underReview:
            "Received and read, with nothing decided yet."
        case .planned:
            "Agreed, and waiting its turn."
        case .inProgress:
            "Being worked on now."
        case .completed:
            "Done, and in a build — check your app version against the release it shipped in."
        case .closedOut:
            "Closed without a change: duplicates, things that turned out not to be faults, "
                + "and requests that will not be built."
        }
    }

    /// Whether this group is live work. Used to keep finished items collapsed
    /// by default rather than hidden.
    var isActive: Bool {
        switch self {
        case .underReview, .planned, .inProgress: true
        case .completed, .closedOut: false
        }
    }
}

// MARK: - Category

/// Bug, or request.
enum CommunityIssueCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case bug
    case feature
    case question
    case other

    /// BugDrop's own category labels, plus the obvious hand-added synonyms.
    static func resolve(labels: [String]) -> Self {
        let lowered = Set(labels.map { $0.lowercased() })
        // Bug first: a report that also got tagged `enhancement` because the
        // fix is a change is still, to the person who filed it, a bug.
        if lowered.contains("bug") || lowered.contains("defect") { return .bug }
        if lowered.contains("enhancement") || lowered.contains("feature")
            || lowered.contains("feature request") { return .feature }
        if lowered.contains("question") { return .question }
        return .other
    }

    var label: String {
        switch self {
        case .bug: "Bug Report"
        case .feature: "Feature Request"
        case .question: "Question"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .bug: "ant"
        case .feature: "lightbulb"
        case .question: "questionmark.bubble"
        case .other: "text.bubble"
        }
    }
}

/// What the filter at the top of the screen is set to.
///
/// Three, and no "everything" among them. The two live tabs answer the only
/// two questions somebody arrives with — *is my problem known?* and *has
/// anybody asked for this?* — and finished work is a third place rather than a
/// tail on both of them.
enum CommunityIssueFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
    case bugs
    case features
    case closed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bugs: "Bugs"
        case .features: "Requests"
        case .closed: "Closed"
        }
    }

    var systemImage: String {
        switch self {
        case .bugs: "ant"
        case .features: "lightbulb"
        case .closed: "archivebox"
        }
    }

    func accepts(_ issue: CommunityIssue) -> Bool {
        let isLive = issue.status.group.isActive
        switch self {
        case .bugs:
            // Everything still open that is *not* a feature request, rather
            // than only what carries a `bug` label. With no "All" tab, an
            // issue nobody has labelled yet — or a question — would otherwise
            // be visible nowhere at all, and invisible is the one place a
            // report must never end up.
            return isLive && issue.category != .feature
        case .features:
            return isLive && issue.category == .feature
        case .closed:
            // Every category, because once something is finished what it was
            // filed as matters less than what came of it.
            return !isLive
        }
    }
}

// MARK: - Reading what GitHub sends

/// The handful of fields this app reads from GitHub's issue JSON.
///
/// Deliberately narrow. Everything GitHub sends that is not listed here is
/// ignored rather than stored, which keeps this from quietly becoming a mirror
/// of somebody's GitHub profile.
struct GitHubIssuePayload: Decodable {
    struct Label: Decodable { let name: String }
    struct User: Decodable { let login: String }
    /// Present only on pull requests. Its presence is the whole signal.
    struct PullRequestMarker: Decodable {}

    let number: Int
    let title: String
    let body: String?
    let state: String
    let stateReason: String?
    let labels: [Label]
    let user: User?
    let createdAt: Date
    let updatedAt: Date
    let comments: Int
    let htmlURL: String?
    let pullRequest: PullRequestMarker?

    enum CodingKeys: String, CodingKey {
        case number, title, body, state, labels, user, comments
        case stateReason = "state_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case pullRequest = "pull_request"
    }

    /// Whether this is really a pull request. GitHub's issues endpoint returns
    /// both, and a pull request is not a roadmap item.
    var isPullRequest: Bool { pullRequest != nil }
}

extension CommunityIssue {
    /// Turns one GitHub issue into a roadmap item, or returns `nil` if it is
    /// not one.
    init?(payload: GitHubIssuePayload) {
        guard !payload.isPullRequest else { return nil }

        let labels = payload.labels.map(\.name)
        number = payload.number
        title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = Self.description(fromIssueBody: payload.body)
        status = CommunityIssueStatus.resolve(
            isOpen: payload.state.lowercased() == "open",
            stateReason: payload.stateReason,
            labels: labels
        )
        category = CommunityIssueCategory.resolve(labels: labels)
        attribution = Self.attribution(fromIssueBody: payload.body)
        self.labels = labels
        createdAt = payload.createdAt
        updatedAt = payload.updatedAt
        commentCount = payload.comments
        webURL = payload.htmlURL.flatMap(URL.init(string:))
    }

    // MARK: Pulling the person's own words back out

    /// The reporter's description, without the machinery around it.
    ///
    /// BugDrop writes a structured body — `## Submitted by`, `## Description`,
    /// an embedded screenshot, a collapsed `System Info` table and a footer —
    /// and only the description is the person talking. Showing the rest inside
    /// the app would mean showing a base64 image as text and a table of
    /// browser versions that are about the feedback page, not about the app.
    ///
    /// An issue written by hand on github.com has no such headings, so the
    /// whole body is the description. Both shapes have to work.
    static func description(fromIssueBody body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let text = section(named: "Description", in: body) ?? strippedOfMachinery(body)
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The name the reporter put on it, if they put one on it.
    ///
    /// Three things this is careful about. It reads the `## Submitted by`
    /// section, which is the only place a reporter's own name appears — **not**
    /// the issue's GitHub author, which is the app installation that filed it
    /// on their behalf and tells you nothing about who they are. It returns
    /// `nil` when the section is absent, because absent means they left the
    /// name box empty and a blank box is a choice. And it undoes BugDrop's
    /// Markdown escaping, so a name is shown as typed rather than with
    /// backslashes through it.
    static func attribution(fromIssueBody body: String?) -> String? {
        guard let body, let raw = section(named: "Submitted by", in: body) else { return nil }

        var line = raw
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""

        // `**Name** (email)` — the address is dropped rather than shown. The
        // feedback form does not ask for one, so anything here arrived by some
        // other route, and republishing an address inside the app is not this
        // screen's job.
        if let opener = line.lastIndex(of: "("), line.hasSuffix(")") {
            line = String(line[line.startIndex..<opener])
        }

        line = line.trimmingCharacters(in: .whitespaces)
        // The bold wrapper, then the backtick fence BugDrop adds around a name
        // containing an @ so GitHub does not turn it into a mention.
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            line = String(line.dropFirst(2).dropLast(2))
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "`")).trimmingCharacters(in: .whitespaces)
        // `\_`, `\*`, `\[` … back to `_`, `*`, `[`.
        line = unescapingMarkdown(line)
        line = line.replacingOccurrences(of: "https\\://", with: "https://")
            .replacingOccurrences(of: "http\\://", with: "http://")
            .replacingOccurrences(of: "www\\.", with: "www.")
        // The same escaper also HTML-encodes these three, so `Ben & Jerry`
        // arrives as `Ben &amp; Jerry` and has to be put back.
        line = line.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")

        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name is a name, not an essay. Anything this long is either an
        // address pasted into the wrong box or someone testing the field.
        guard !cleaned.isEmpty, cleaned.count <= 80 else { return nil }
        return cleaned
    }

    /// The text under one `## Heading`, up to the next heading of any level.
    private static func section(named name: String, in body: String) -> String? {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false
        )
        guard let start = lines.firstIndex(where: { isHeading($0, named: name) }) else {
            return nil
        }
        var collected: [String] = []
        for line in lines[(start + 1)...] {
            if isAnyHeading(line) { break }
            collected.append(String(line))
        }
        return collected.joined(separator: "\n")
    }

    private static func isHeading(_ line: Substring, named name: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return false }
        let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return text.caseInsensitiveCompare(name) == .orderedSame
    }

    /// `#` through `######` followed by a space — an ATX heading, and not a
    /// line of prose that happens to begin with a hash.
    private static func isAnyHeading(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return false }
        return trimmed.dropFirst(hashes).first == " "
    }

    /// For an issue written by hand: drops the parts of a BugDrop body that are
    /// not prose, in case one was pasted in.
    ///
    /// The data-URL case is the one that matters. A screenshot is embedded as
    /// base64 directly in the body, so an unguarded body can be megabytes of
    /// gibberish, and putting that through a `Text` view would hang the list.
    private static func strippedOfMachinery(_ body: String) -> String {
        var text = body
        // Embedded images, data URLs first and longest.
        text = text.replacingOccurrences(
            of: "!\\[[^\\]]*\\]\\(data:[^)]*\\)",
            with: "",
            options: [.regularExpression]
        )
        // The collapsed System Info block, and the BugDrop footer.
        text = text.replacingOccurrences(
            of: "<details>[\\s\\S]*?</details>",
            with: "",
            options: [.regularExpression]
        )
        text = text.replacingOccurrences(
            of: "\\n---\\s*\\n\\*Submitted via[^\\n]*",
            with: "",
            options: [.regularExpression]
        )
        return text
    }

    private static func unescapingMarkdown(_ text: String) -> String {
        var result = ""
        var isEscaped = false
        for character in text {
            if isEscaped {
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        if isEscaped { result.append("\\") }
        return result
    }
}

// MARK: - A page of results

/// One page of issues, and whether there is another.
struct CommunityIssuePage: Sendable {
    let issues: [CommunityIssue]
    /// The next page's address, taken from the `Link` header. `nil` at the end.
    let nextPageURL: URL?

    /// Parses GitHub's `Link` header for `rel="next"`.
    ///
    /// Following GitHub's own link rather than incrementing a page number: the
    /// cursor-based form it has moved to does not have a page number to
    /// increment, and the header is the documented way through either.
    static func nextPageURL(fromLinkHeader header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";")
            guard pieces.count >= 2 else { continue }
            let isNext = pieces.dropFirst().contains {
                let value = $0.trimmingCharacters(in: .whitespaces)
                return value == "rel=\"next\"" || value == "rel=next"
            }
            guard isNext else { continue }
            let address = pieces[0].trimmingCharacters(in: .whitespaces)
            guard address.hasPrefix("<"), address.hasSuffix(">") else { continue }
            // Only ever GitHub's own API. A `Link` header is a value from the
            // network deciding where the app goes next, so it is checked
            // rather than trusted.
            guard
                let url = URL(string: String(address.dropFirst().dropLast())),
                url.scheme == "https",
                url.host?.lowercased() == "api.github.com"
            else { continue }
            return url
        }
        return nil
    }
}
