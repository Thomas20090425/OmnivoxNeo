// Checks on the roadmap parsing, run against the shipping source rather than
// a copy of it.
//
//     Tests/run-community-issue-tests.sh
//
// which compiles this file together with OmnivoxNeo/Models/CommunityIssue.swift
// and runs it. There is no XCTest target in this project, and adding one to
// drive four hundred lines of pure value types would be more machinery than
// the thing being tested. What matters is that the code under test is the file
// that ships, so a change to the parser either keeps these passing or is
// caught here.
//
// The fixtures are real shapes: GitHub's issues JSON as it actually arrives,
// and a BugDrop issue body with the exact headings BugDrop writes.

import Foundation

var failures = 0
var checks = 0

func expect(
    _ condition: Bool,
    _ what: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checks += 1
    if !condition {
        failures += 1
        print("  ✗ \(what)   (line \(line))")
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ what: String,
    line: UInt = #line
) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  ✗ \(what)")
        print("      expected: \(expected)")
        print("      actual:   \(actual)")
        print("      (line \(line))")
    }
}

func section(_ name: String) { print("\n\(name)") }

func decode(_ json: String) -> [GitHubIssuePayload] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode([GitHubIssuePayload].self, from: Data(json.utf8))
    } catch {
        print("  ✗ fixture failed to decode: \(error)")
        failures += 1
        return []
    }
}

/// One issue, with only the fields a test cares about spelled out.
func issueJSON(
    number: Int,
    title: String = "A title",
    body: String? = nil,
    state: String = "open",
    stateReason: String? = nil,
    labels: [String] = [],
    comments: Int = 0,
    isPullRequest: Bool = false,
    updatedAt: String = "2026-10-12T18:04:11Z",
    createdAt: String = "2026-10-01T09:00:00Z"
) -> String {
    let labelJSON = labels
        .map { #"{"id":1,"name":"\#($0)","color":"ededed"}"# }
        .joined(separator: ",")
    let bodyJSON: String
    if let body {
        let escaped = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        bodyJSON = "\"\(escaped)\""
    } else {
        bodyJSON = "null"
    }
    let reason = stateReason.map { "\"\($0)\"" } ?? "null"
    let pull = isPullRequest
        ? #","pull_request":{"url":"https://api.github.com/repos/o/r/pulls/\#(number)"}"#
        : ""
    return """
    {
      "id": \(number * 1000),
      "number": \(number),
      "title": "\(title)",
      "body": \(bodyJSON),
      "state": "\(state)",
      "state_reason": \(reason),
      "labels": [\(labelJSON)],
      "user": {"login": "bugdrop-app[bot]", "id": 4242, "type": "Bot"},
      "assignees": [],
      "comments": \(comments),
      "created_at": "\(createdAt)",
      "updated_at": "\(updatedAt)",
      "closed_at": null,
      "html_url": "https://github.com/Thomas20090425/OmnivoxNeo/issues/\(number)",
      "author_association": "NONE"\(pull)
    }
    """
}

@main
enum CommunityIssueTests {
static func main() {

// MARK: - Decoding what GitHub actually sends

section("Decoding")

do {
    // Deliberately includes fields the app does not read, because GitHub sends
    // dozens of them and a decoder that chokes on an unknown key would break
    // the day GitHub adds one.
    let payloads = decode("[\(issueJSON(number: 7, title: "Grades show as a dash", labels: ["bug"], comments: 3))]")
    expectEqual(payloads.count, 1, "one issue decodes")
    if let first = payloads.first {
        expectEqual(first.number, 7, "number")
        expectEqual(first.title, "Grades show as a dash", "title")
        expectEqual(first.comments, 3, "comment count")
        expectEqual(first.labels.map(\.name), ["bug"], "labels")
        expect(!first.isPullRequest, "not flagged as a pull request")
        expectEqual(
            first.updatedAt,
            ISO8601DateFormatter().date(from: "2026-10-12T18:04:11Z"),
            "updated_at parses as a real date"
        )
    }
}

do {
    let empty = decode("[]")
    expectEqual(empty.count, 0, "an empty repository decodes to no issues")
}

do {
    // GitHub's issues endpoint returns pull requests too. They are not roadmap
    // items and must not appear.
    let mixed = decode("""
    [\(issueJSON(number: 1, labels: ["bug"])),
     \(issueJSON(number: 2, title: "Fix the thing", isPullRequest: true)),
     \(issueJSON(number: 3, labels: ["enhancement"]))]
    """)
    expectEqual(mixed.count, 3, "all three decode")
    let issues = mixed.compactMap(CommunityIssue.init(payload:))
    expectEqual(issues.count, 2, "the pull request is dropped")
    expectEqual(issues.map(\.number), [1, 3], "the right two survive")
}

do {
    // A body with no `## Description` heading — someone wrote the issue by
    // hand on github.com.
    let hand = decode("[\(issueJSON(number: 9, body: "The schedule is blank after midnight.", labels: ["bug"]))]")
    let issue = hand.compactMap(CommunityIssue.init(payload:)).first
    expectEqual(issue?.summary, "The schedule is blank after midnight.", "a hand-written body is the summary")
    expect(issue?.attribution == nil, "a hand-written issue has no reporter name")
}

// MARK: - Status

section("Status mapping")

do {
    typealias Case = (isOpen: Bool, reason: String?, labels: [String], expected: CommunityIssueStatus)
    let cases: [Case] = [
        (true,  nil,            [],                      .underReview),
        (true,  nil,            ["bug"],                 .underReview),
        (true,  nil,            ["status:planned"],      .planned),
        (true,  nil,            ["status: planned"],     .planned),
        (true,  nil,            ["Planned"],             .planned),
        (true,  nil,            ["status:in-progress"],  .inProgress),
        (true,  nil,            ["in progress"],         .inProgress),
        // In-progress beats planned: it is the more specific claim.
        (true,  nil,            ["status:planned", "status:in-progress"], .inProgress),
        (false, "completed",    [],                      .completed),
        (false, "not_planned",  [],                      .notPlanned),
        (false, "duplicate",    [],                      .duplicate),
        (false, "not_planned",  ["duplicate"],           .duplicate),
        (false, nil,            ["duplicate"],           .duplicate),
        (false, nil,            ["wontfix"],             .notPlanned),
        // The one that matters most: closed with no stated reason is NOT
        // "completed". Telling somebody their bug was fixed on no evidence is
        // the app inventing good news.
        (false, nil,            [],                      .closed),
        (false, nil,            ["bug"],                 .closed),
        (false, "reopened",     [],                      .closed)
    ]
    for item in cases {
        let actual = CommunityIssueStatus.resolve(
            isOpen: item.isOpen, stateReason: item.reason, labels: item.labels
        )
        expectEqual(
            actual, item.expected,
            "open=\(item.isOpen) reason=\(item.reason ?? "nil") labels=\(item.labels)"
        )
    }
}

do {
    // Finished work must not sit among live work.
    expectEqual(CommunityIssueStatus.completed.group, .completed, "completed has its own group")
    expectEqual(CommunityIssueStatus.closed.group, .closedOut, "closed groups with the closed-out items")
    expectEqual(CommunityIssueStatus.duplicate.group, .closedOut, "duplicates group with closed-out")
    expectEqual(CommunityIssueStatus.notPlanned.group, .closedOut, "not-planned groups with closed-out")
    for active in [CommunityIssueStatus.underReview, .planned, .inProgress] {
        expect(active.group.isActive, "\(active.label) is live work")
    }
    for done in [CommunityIssueStatus.completed, .closed, .duplicate, .notPlanned] {
        expect(!done.group.isActive, "\(done.label) is not live work")
    }
    // A closed issue with no reason says "Closed" on itself even though it
    // sits under the Not Planned or Closed heading.
    expectEqual(CommunityIssueStatus.closed.label, "Closed", "its own label is honest")
    expectEqual(CommunityIssueGroup.closedOut.title, "Not Planned or Closed", "the heading covers both")
    expectEqual(
        CommunityIssueGroup.displayOrder,
        [.inProgress, .planned, .underReview, .completed, .closedOut],
        "live work first, finished work last"
    )
}

// MARK: - Category

section("Category mapping")

do {
    typealias Case = (labels: [String], expected: CommunityIssueCategory)
    let cases: [Case] = [
        (["bug"],                     .bug),
        (["Bug"],                     .bug),
        (["enhancement"],             .feature),
        (["feature request"],         .feature),
        (["question"],                .question),
        ([],                          .other),
        (["documentation"],           .other),
        // A bug whose fix is a change still reads as a bug to whoever filed it.
        (["bug", "enhancement"],      .bug)
    ]
    for item in cases {
        expectEqual(
            CommunityIssueCategory.resolve(labels: item.labels), item.expected,
            "labels \(item.labels)"
        )
    }
}

do {
    // The three tabs the screen offers. There is no "All", so the rule that
    // matters most is that every issue lands in exactly one of them.
    func make(_ json: String) -> CommunityIssue {
        CommunityIssue(payload: decode("[\(json)]")[0])!
    }
    let bug = make(issueJSON(number: 1, labels: ["bug"]))
    let feature = make(issueJSON(number: 2, labels: ["enhancement"]))
    let question = make(issueJSON(number: 3, labels: ["question"]))
    let unlabelled = make(issueJSON(number: 4, labels: []))
    let doneBug = make(issueJSON(number: 5, state: "closed", stateReason: "completed", labels: ["bug"]))
    let doneFeature = make(issueJSON(number: 6, state: "closed", stateReason: "completed", labels: ["enhancement"]))
    let rejected = make(issueJSON(number: 7, state: "closed", stateReason: "not_planned", labels: ["enhancement"]))

    expect(CommunityIssueFilter.bugs.accepts(bug), "Bugs takes an open bug")
    expect(!CommunityIssueFilter.bugs.accepts(feature), "Bugs rejects a request")
    expect(CommunityIssueFilter.features.accepts(feature), "Requests takes an open request")
    expect(!CommunityIssueFilter.features.accepts(bug), "Requests rejects a bug")

    // With no "All" tab, anything open that nobody categorised has to surface
    // somewhere, and Bugs is that somewhere.
    expect(CommunityIssueFilter.bugs.accepts(question), "Bugs takes an open question")
    expect(CommunityIssueFilter.bugs.accepts(unlabelled), "Bugs takes an open unlabelled issue")

    // Closed work leaves the live tabs entirely.
    for done in [doneBug, doneFeature, rejected] {
        expect(!CommunityIssueFilter.bugs.accepts(done), "Bugs holds nothing finished (#\(done.number))")
        expect(!CommunityIssueFilter.features.accepts(done), "Requests holds nothing finished (#\(done.number))")
        expect(CommunityIssueFilter.closed.accepts(done), "Closed takes it instead (#\(done.number))")
    }
    for live in [bug, feature, question, unlabelled] {
        expect(!CommunityIssueFilter.closed.accepts(live), "Closed holds nothing live (#\(live.number))")
    }

    // Exactly one tab, for every issue, every time.
    for issue in [bug, feature, question, unlabelled, doneBug, doneFeature, rejected] {
        let matching = CommunityIssueFilter.allCases.filter { $0.accepts(issue) }
        expectEqual(matching.count, 1, "#\(issue.number) appears under exactly one tab")
    }
}

// MARK: - Reading a BugDrop body

section("BugDrop issue bodies")

/// Exactly the shape `formatIssueBody` in BugDrop's worker produces.
let bugDropBody = """
## Submitted by
**Alex**

## Description
The schedule is blank after midnight. It comes back if I force quit.

## Screenshot
![Screenshot](https://example.invalid/.bugdrop/screenshots/1.png)

<details>
<summary>System Info</summary>

| Property | Value |
|----------|-------|
| **App Version** | `0.0.5.3` |
| **Browser** | Safari 26 |
| **OS** | iOS 18 |
| **Page** | https://example.invalid/feedback.html |

</details>

---
*Submitted via [BugDrop](https://github.com/mean-weasel/bugdrop)*
"""

do {
    expectEqual(
        CommunityIssue.description(fromIssueBody: bugDropBody),
        "The schedule is blank after midnight. It comes back if I force quit.",
        "only the reporter's own words are taken as the summary"
    )
    expectEqual(
        CommunityIssue.attribution(fromIssueBody: bugDropBody), "Alex",
        "the name is unwrapped from its bold markers"
    )
}

do {
    // No "## Submitted by" section at all: the name box was left empty, and
    // that is a choice, not missing data.
    let anonymous = bugDropBody
        .replacingOccurrences(of: "## Submitted by\n**Alex**\n\n", with: "")
    expect(
        CommunityIssue.attribution(fromIssueBody: anonymous) == nil,
        "an empty name box reads as anonymous"
    )
    expectEqual(
        CommunityIssue.description(fromIssueBody: anonymous),
        "The schedule is blank after midnight. It comes back if I force quit.",
        "the description still reads without a name section"
    )
}

do {
    // BugDrop escapes Markdown in the name, and fences a name containing an @
    // in backticks so GitHub does not turn it into a mention. Both have to be
    // undone, or the name is shown with backslashes through it.
    expectEqual(
        CommunityIssue.attribution(fromIssueBody: "## Submitted by\n**Marie\\-Claude**\n"),
        "Marie-Claude", "a backslash-escaped hyphen is put back"
    )
    expectEqual(
        CommunityIssue.attribution(fromIssueBody: "## Submitted by\n**`someone@example.com`**\n"),
        "someone@example.com", "the backtick fence around an @ name is removed"
    )
    expectEqual(
        CommunityIssue.attribution(fromIssueBody: "## Submitted by\n**Ben &amp; Jerry**\n"),
        "Ben & Jerry", "HTML entities are decoded"
    )
    expectEqual(
        CommunityIssue.attribution(fromIssueBody: "## Submitted by\n**Alex** (alex@example.com)\n"),
        "Alex", "an address is dropped rather than republished"
    )
    expect(
        CommunityIssue.attribution(fromIssueBody: "## Submitted by\n**\(String(repeating: "a", count: 200))**\n") == nil,
        "something far too long to be a name is refused"
    )
}

do {
    // The failure that would actually hurt: a screenshot embedded as a base64
    // data URL. These run to megabytes, and putting one through a Text view as
    // the issue summary would lock up the list.
    let huge = "![Screenshot](data:image/png;base64,\(String(repeating: "A", count: 400_000)))"
    let body = "Something broke.\n\n\(huge)"
    let summary = CommunityIssue.description(fromIssueBody: body) ?? ""
    expect(summary.count < 200, "an embedded base64 screenshot is stripped, not shown (got \(summary.count) characters)")
    expectEqual(summary, "Something broke.", "the prose around it survives")
}

do {
    expect(CommunityIssue.description(fromIssueBody: nil) == nil, "a null body is nil, not empty string")
    expect(CommunityIssue.description(fromIssueBody: "") == nil, "an empty body is nil")
    expect(CommunityIssue.description(fromIssueBody: "   \n\n  ") == nil, "a whitespace body is nil")
    expect(CommunityIssue.attribution(fromIssueBody: nil) == nil, "a null body has no name")
    expect(
        CommunityIssue.attribution(fromIssueBody: "## Submitted by\n\n## Description\nhi") == nil,
        "an empty Submitted by section has no name"
    )
}

do {
    // A line of prose starting with "#" is not a heading and must not cut the
    // description short.
    let body = "## Description\nIt says #1 priority but nothing happens.\nSecond line.\n\n## Screenshot\nx"
    expectEqual(
        CommunityIssue.description(fromIssueBody: body),
        "It says #1 priority but nothing happens.\nSecond line.",
        "a hash inside prose does not end the section"
    )
}

// MARK: - Paging

section("Pagination")

do {
    let header = """
    <https://api.github.com/repositories/1/issues?page=2>; rel="next", \
    <https://api.github.com/repositories/1/issues?page=9>; rel="last"
    """
    expectEqual(
        CommunityIssuePage.nextPageURL(fromLinkHeader: header)?.absoluteString,
        "https://api.github.com/repositories/1/issues?page=2",
        "the next page is followed from the Link header"
    )
}

do {
    let lastPage = #"<https://api.github.com/repositories/1/issues?page=1>; rel="prev", <https://api.github.com/repositories/1/issues?page=1>; rel="first""#
    expect(
        CommunityIssuePage.nextPageURL(fromLinkHeader: lastPage) == nil,
        "the last page has no next"
    )
    expect(CommunityIssuePage.nextPageURL(fromLinkHeader: nil) == nil, "no header means no next")
    expect(CommunityIssuePage.nextPageURL(fromLinkHeader: "") == nil, "an empty header means no next")
    expect(CommunityIssuePage.nextPageURL(fromLinkHeader: "garbage") == nil, "a malformed header means no next")
}

do {
    // A Link header is the network telling the app where to go next, so it is
    // checked rather than trusted.
    let offHost = #"<https://evil.invalid/issues?page=2>; rel="next""#
    expect(
        CommunityIssuePage.nextPageURL(fromLinkHeader: offHost) == nil,
        "a next page pointing somewhere other than GitHub is refused"
    )
    let insecure = #"<http://api.github.com/issues?page=2>; rel="next""#
    expect(
        CommunityIssuePage.nextPageURL(fromLinkHeader: insecure) == nil,
        "a plain-HTTP next page is refused"
    )
}

// MARK: - Grouping end to end

section("Grouping")

do {
    let json = """
    [\(issueJSON(number: 1, title: "Blank schedule", body: "## Description\\nblank", labels: ["bug"])),
     \(issueJSON(number: 2, title: "Dark mode", labels: ["enhancement", "status:planned"])),
     \(issueJSON(number: 3, title: "Widget crash", labels: ["bug", "status:in-progress"])),
     \(issueJSON(number: 4, title: "Fixed grades", state: "closed", stateReason: "completed", labels: ["bug"])),
     \(issueJSON(number: 5, title: "Old duplicate", state: "closed", stateReason: nil, labels: ["bug", "duplicate"])),
     \(issueJSON(number: 6, title: "Mystery", state: "closed", stateReason: nil, labels: [])),
     \(issueJSON(number: 7, title: "A pull request", isPullRequest: true))]
    """
    let issues = decode(json).compactMap(CommunityIssue.init(payload:))
    expectEqual(issues.count, 6, "six roadmap items, the pull request excluded")

    func group(_ which: CommunityIssueGroup) -> [Int] {
        issues.filter { $0.status.group == which }.map(\.number).sorted()
    }
    expectEqual(group(.underReview), [1], "under review")
    expectEqual(group(.planned), [2], "planned")
    expectEqual(group(.inProgress), [3], "in progress")
    expectEqual(group(.completed), [4], "completed, and on its own")
    expectEqual(group(.closedOut), [5, 6], "duplicate and unexplained-closed together")

    let bugs = issues.filter(CommunityIssueFilter.bugs.accepts).map(\.number).sorted()
    expectEqual(bugs, [1, 3], "the Bugs tab: open only, and #4 and #5 are closed bugs")
    let requests = issues.filter(CommunityIssueFilter.features.accepts).map(\.number).sorted()
    expectEqual(requests, [2], "the Requests tab")
    let closed = issues.filter(CommunityIssueFilter.closed.accepts).map(\.number).sorted()
    expectEqual(closed, [4, 5, 6], "the Closed tab: finished, duplicate and unexplained alike")
    expectEqual(
        (bugs + requests + closed).sorted(), issues.map(\.number).sorted(),
        "the three tabs between them account for every issue, with none counted twice"
    )

    // Nothing finished is mixed in with live work.
    let live = issues.filter { $0.status.group.isActive }.map(\.number).sorted()
    expectEqual(live, [1, 2, 3], "live work holds no finished items")
}

// MARK: - Result

print("")
if failures == 0 {
    print("All \(checks) checks passed.")
    exit(0)
} else {
    print("\(failures) of \(checks) checks FAILED.")
    exit(1)
}

}
}
