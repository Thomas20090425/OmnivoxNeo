import Foundation

/// Everything Léa — the OmniVox classroom — publishes about one term.
///
/// Léa lives on its own host, reached by an SSO hop from the portal, and its
/// pages are classic ASP.NET tables rather than the newer portal chrome. So the
/// shapes here are deliberately close to what the pages actually say: a grade is
/// a *string* like "19.5/25" because that is what the teacher entered and any
/// attempt to normalise it loses information the student is looking at.
///
/// Anything the portal did not print is `nil` rather than a zero. "No mark yet"
/// and "a mark of zero" are opposite pieces of news.

// MARK: - Term

/// One selectable term in Léa's term picker.
struct LeaTerm: Identifiable, Hashable, Sendable, Codable {
    /// The value the page's own control uses. Opaque on purpose — it is a
    /// postback token, not something to parse.
    let value: String
    let title: String
    let isCurrent: Bool

    var id: String { value }
}

// MARK: - Course

/// A course as Léa's landing page summarises it.
///
/// The landing page is the only screen that shows every course at once, so it
/// is also the only cheap way to know what exists. Each section below carries
/// the link to its own page; the detail is fetched when the student asks for it
/// rather than up front, because a full sweep is seven page loads.
struct LeaCourse: Identifiable, Hashable, Sendable, Codable {
    /// `201-MA1-DW` — the ministry course code.
    let code: String
    /// `CALCULUS I: DIFFERENTIAL CALCULUS FOR SOCIAL…`
    let title: String
    /// `sect. 00005 - Mon 10:00, Wed 10:00, Fri 12:00, Georgeana Bobos-Kristof`
    let subtitle: String
    /// The teacher's name, when it can be told apart from the schedule.
    let teacher: String?
    /// Which of Léa's own header colours this course was drawn in, so the app
    /// can keep a course recognisable by colour across screens.
    let paletteIndex: Int

    var sections: [LeaSection]

    var id: String { code + "|" + subtitle }

    func section(_ kind: LeaSection.Kind) -> LeaSection? {
        sections.first { $0.kind == kind }
    }

    /// Everything the course wants the student to look at, summed for a badge.
    var unreadCount: Int {
        sections.reduce(0) { $0 + $1.unreadCount }
    }
}

/// One row inside a course card.
struct LeaSection: Hashable, Sendable, Codable {
    /// Identified by the SVG symbol Léa draws, not by its label.
    ///
    /// The labels are translated — "Announcements" / "Annonces" — but the
    /// `<use href="#msgs">` under them is not, so the icon is the only stable
    /// name these rows have.
    enum Kind: String, Hashable, Sendable, Codable {
        case onlineClass
        case documents
        case assignments
        case grades
        case announcements
        case absences
        case events
        case forum
        case unknown
    }

    let kind: Kind
    /// Léa's own label, already in the student's language.
    let label: String
    /// The value printed on the right of the row: "Classroom", "Not enabled",
    /// "1 h".
    let trailingText: String?
    /// Where this section's own page lives, when the row is a link.
    let url: URL?
    /// The counted rows underneath, in order.
    var metrics: [LeaMetric]
    /// Announcements are summarised inline on the card rather than counted.
    var announcements: [LeaAnnouncementSummary]
    /// So are the next few events.
    var events: [LeaEventSummary]

    /// How many things in this section the student has not seen.
    var unreadCount: Int {
        metrics.reduce(0) { $0 + ($1.isNew ? ($1.count ?? 0) : 0) }
            + announcements.filter(\.isNew).count
    }
}

/// A "Distributed documents 21" / "New documents 7" row.
struct LeaMetric: Hashable, Sendable, Codable {
    let label: String
    /// The numeric value, when the row carries one.
    let count: Int?
    /// The value as printed, for rows whose value is not a number
    /// ("2.0/2", "100%", "—").
    let text: String?
    /// The second line of a stacked value — the "89%" under a "14.2/16".
    ///
    /// Separate rather than appended, because running the two together is
    /// exactly how a grade of 14.2 out of 16 came to read as "14.2/1689%".
    let detail: String?
    /// True for Léa's orange "new since last visit" counter.
    let isNew: Bool
}

struct LeaAnnouncementSummary: Identifiable, Hashable, Sendable, Codable {
    let date: String
    let title: String
    let url: URL?
    let isNew: Bool

    var id: String { (url?.absoluteString ?? "") + date + title }
}

struct LeaEventSummary: Identifiable, Hashable, Sendable, Codable {
    let date: String
    let title: String
    let detail: String?
    let url: URL?

    var id: String { date + title }
}

// MARK: - Announcement

struct LeaAnnouncement: Hashable, Sendable {
    let title: String
    let courseLine: String?
    let byline: String?
    /// The body as Léa wrote it, HTML and all. Rendered rather than stripped:
    /// teachers use lists and bold, and flattening it loses their meaning.
    let bodyHTML: String
}

// MARK: - Documents

struct LeaDocumentCategory: Identifiable, Hashable, Sendable {
    let name: String
    var documents: [LeaDocument]

    var id: String { name }
}

struct LeaDocument: Identifiable, Hashable, Sendable {
    /// What happens when it is tapped.
    enum Destination: Hashable, Sendable {
        /// A file served by Léa itself. The URL both downloads it *and* tells
        /// Léa it has been seen, which is why opening it clears the star.
        case file(name: String?, size: String?, url: URL)
        /// A site the teacher linked to. Left to the browser, after asking.
        case externalLink(URL)
    }

    let title: String
    let detail: String?
    /// "Must have read this document for September 28, 2026", verbatim.
    let requiredBy: String?
    /// "since Aug 21, 2026", verbatim.
    let availableSince: String?
    let isUnread: Bool
    let destination: Destination

    var id: String {
        switch destination {
        case .file(_, _, let url): url.absoluteString
        case .externalLink(let url): url.absoluteString + title
        }
    }
}

// MARK: - Assignments

struct LeaAssignment: Identifiable, Hashable, Sendable {
    let category: String?
    let title: String
    /// "Sep-14, 2026 at 14:00", verbatim — Léa's own formatting, in the
    /// student's language.
    let dueText: String?
    /// How it is handed in ("via Léa").
    let dueVia: String?
    /// Léa prints an overdue deadline in red; that is the only signal it gives.
    let isOverdue: Bool
    /// Instructions the student has never opened.
    let hasUnreadInstructions: Bool
    /// The submission page: instructions, and the upload form.
    let instructionsURL: URL?
    /// What was handed in, if anything.
    let submissionText: String?
    let submissionURL: URL?
    /// The teacher's marked-up copy coming back.
    let correctedCopyURL: URL?

    var id: String { (instructionsURL?.absoluteString ?? title) }

    /// A marked copy coming back entails work having gone out — the strongest
    /// evidence of completion a row carries, and stronger than the deposit
    /// link itself, which a teacher can remove.
    var hasMarkedCopy: Bool { correctedCopyURL != nil }

    /// Whether Léa has a record of something handed in.
    ///
    /// True if *any* part of the deposit survived the read: the link, the text
    /// Léa printed on it, or a marked copy coming back. Reading only the text
    /// is what made a submitted assignment claim it was not: Léa sometimes
    /// draws that link as an icon, and an icon's text is stripped before the
    /// page is read.
    ///
    /// The absence of all three is **not** evidence of the opposite. A teacher
    /// who collects work on paper leaves no link at all, and nothing anywhere
    /// on the page says "not handed in" — which is why nothing in the app says
    /// it either.
    var isHandedIn: Bool {
        submissionURL != nil || submissionText != nil || correctedCopyURL != nil
    }
}

// MARK: - Grades

struct LeaGradeCategory: Identifiable, Hashable, Sendable {
    let name: String
    /// "17% of final grade", verbatim.
    let weightText: String?
    /// "95.1%  (9.5/10.0)", verbatim.
    let averageText: String?
    /// "The 4 lowest results in this category will be discarded.", verbatim.
    ///
    /// Kept as Léa's own sentence rather than reduced to a number, because the
    /// rule differs by teacher — some drop the lowest one, some the lowest
    /// four, some only if it helps — and a paraphrase would be a guess about a
    /// number the student is trying to plan around.
    let dropRule: String?
    var items: [LeaGradeItem]

    var id: String { name }

    /// True when some of this category's marks will not count.
    ///
    /// Either because Léa announced the rule at the top, or because it marked
    /// individual rows as dropped without announcing it. Both happen.
    var dropsMarks: Bool {
        dropRule != nil || items.contains(where: \.isDiscarded)
    }

    /// The marks that actually count towards the average.
    var countedItems: [LeaGradeItem] {
        items.filter { !$0.isDiscarded }
    }
}

struct LeaGradeItem: Identifiable, Hashable, Sendable {
    let position: String?
    let title: String
    /// The date Léa prints under the title for scheduled assessments.
    let date: String?
    /// "19.5/25", or nil when the row is a dash — no data yet.
    let mark: String?
    /// "78%"
    let markPercent: String?
    let classAverage: String?
    /// "6%"
    let weight: String?
    /// "(4.68/6)"
    let weightPoints: String?
    /// True when this mark will not count towards the category's average.
    ///
    /// Teachers who drop the lowest few results leave every mark visible, so
    /// nothing in the numbers says which of them still counts. Léa says it —
    /// in a sentence under the title, and by greying the row — and a student
    /// working out what they need on the next test is reading exactly this.
    let isDiscarded: Bool
    /// Léa's own sentence saying so, when it printed one.
    let discardNote: String?
    let comment: LeaGradeComment?

    var id: String { title + (position ?? "") }

    /// Léa prints a dash for anything not yet released.
    var isReleased: Bool { mark != nil }

    /// How much of this assessment was earned, 0…1.
    ///
    /// Read from the percentage Léa prints when there is one, and worked out
    /// from the mark when there is not. Returns nil rather than guessing for a
    /// mark written in a notation this does not recognise — a bar drawn from a
    /// misread number is worse than no bar.
    var fraction: Double? {
        if let percent = LeaGradeItem.number(in: markPercent, endingIn: "%") {
            return min(max(percent / 100, 0), 1)
        }
        guard
            let mark,
            case let parts = mark.split(separator: "/"),
            parts.count == 2,
            let earned = Double(parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
            let total = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
            total > 0
        else { return nil }
        return min(max(earned / total, 0), 1)
    }

    /// The class's share of the same assessment, for comparison.
    var classFraction: Double? {
        guard
            let classAverage,
            case let parts = classAverage.split(separator: "/"),
            parts.count == 2,
            let earned = Double(parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
            let total = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
            total > 0
        else {
            guard let percent = LeaGradeItem.number(in: classAverage, endingIn: "%") else { return nil }
            return min(max(percent / 100, 0), 1)
        }
        return min(max(earned / total, 0), 1)
    }

    private static func number(in text: String?, endingIn suffix: String) -> Double? {
        guard let text, text.hasSuffix(suffix) else { return nil }
        return Double(
            text.dropLast(suffix.count)
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespaces)
        )
    }
}

struct LeaGradeComment: Hashable, Sendable {
    let heading: String
    let body: String
}

/// One of the numbers Léa prints under "Class Statistics".
///
/// Carried as a label and a value rather than as named fields, because the
/// labels arrive already translated and the set differs by course — a teacher
/// who hides the class average simply has one fewer row.
struct LeaGradeStatistic: Identifiable, Hashable, Sendable {
    let label: String
    let value: String

    var id: String { label }

    /// The value as a number, when it is a percentage, for drawing.
    var percent: Double? {
        let digits = value.replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." }
        guard value.contains("%"), let number = Double(digits) else { return nil }
        return number
    }
}

/// One point on the average-progression graph.
///
/// Léa serves that graph as a server-rendered image, but spells every point out
/// in the tooltip behind it. Those numbers are read instead, so the chart can
/// be drawn at the reader's own text size, recoloured for dark mode, and — the
/// part an image can never do — read aloud.
struct LeaGradePoint: Identifiable, Hashable, Sendable {
    /// 0 for the student's own line, 1 for the class average.
    let series: Int
    /// Léa's own name for the line, already in the student's language.
    let seriesName: String
    /// Which assessment this point follows.
    let step: Int
    /// The running average at that point, as a percentage.
    let value: Double
    /// How much of the final grade had been handed back by then.
    let cumulative: Double
    /// "Sep-01, 2026", verbatim.
    let date: String?

    var id: String { "\(series)-\(step)" }
}

/// The block Léa calls "Course summary", plus its progression chart.
struct LeaGradeSummary: Hashable, Sendable {
    /// "14.2/16"
    let currentGrade: String?
    /// "89%"
    let currentPercent: String?
    let statistics: [LeaGradeStatistic]
    let progression: [LeaGradePoint]

    /// The student's own line, in order.
    var yourProgression: [LeaGradePoint] {
        progression.filter { $0.series == 0 }.sorted { $0.cumulative < $1.cumulative }
    }

    /// The class's line, in order.
    var classProgression: [LeaGradePoint] {
        progression.filter { $0.series == 1 }.sorted { $0.cumulative < $1.cumulative }
    }

    /// The percentage as a number, for the gauge.
    var percentValue: Double? {
        guard let text = currentPercent else { return nil }
        let digits = text.replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." }
        return Double(digits)
    }
}

struct LeaGrades: Hashable, Sendable {
    let teacher: String?
    var categories: [LeaGradeCategory]
    var summary: LeaGradeSummary?

    /// Marks that have actually come back, newest first — what a student
    /// opening this screen is usually looking for.
    var releasedItems: [LeaGradeItem] {
        categories.flatMap(\.items).filter(\.isReleased)
    }
}

// MARK: - Recommended sites

struct LeaTeacherSites: Identifiable, Hashable, Sendable {
    let teacher: String
    let courseCode: String
    /// Absent when the teacher has not recommended anything — Léa prints "- -".
    let url: URL?

    var id: String { teacher + courseCode }
}

struct LeaSiteCategory: Identifiable, Hashable, Sendable {
    let name: String
    var sites: [LeaSite]

    var id: String { name }
}

struct LeaSite: Identifiable, Hashable, Sendable {
    let title: String
    let url: URL
    let detail: String?

    var id: String { url.absoluteString + title }
}

// MARK: - The whole term

/// One fetch of Léa's landing page.
struct LeaOverview: Hashable, Sendable {
    var terms: [LeaTerm]
    var selectedTerm: String?
    var courses: [LeaCourse]
    /// True when Léa itself said there is nothing in this term, as opposed to
    /// the app failing to read the page.
    var isEmptyTerm: Bool
    var fetchedAt: Date

    static let empty = LeaOverview(
        terms: [],
        selectedTerm: nil,
        courses: [],
        isEmptyTerm: false,
        fetchedAt: .distantPast
    )
}
