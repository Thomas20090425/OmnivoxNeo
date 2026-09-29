import Foundation

struct PortalLinkRecord: Codable, Hashable, Sendable {
    let title: String
    let url: String
}

struct PortalCalendarRecord: Codable, Hashable, Sendable {
    let isoStartDate: String
    let isoEndDate: String?
    let categoryCode: String
    let title: String
    let timeText: String?
    let subtitle: String?
    let detail: String?
    let location: String?
    let links: [PortalLinkRecord]?
    let communityTitle: String?
    let communityURL: String?
}

struct PortalUpdateRecord: Codable, Hashable, Sendable {
    let kind: String
    let title: String
    let detail: String?
}

enum PortalContentParser {
    static func parseFirstName(_ displayName: String?) -> String? {
        guard let displayName else { return nil }
        return displayName
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)
    }

    /// The student's full name, normalized for display.
    ///
    /// OmniVox writes names inconsistently — non-breaking spaces, an all-caps
    /// surname, and sometimes `LAST, First` order. All three are flattened here
    /// so the account list can show "Thomas Ma" whatever the portal sent.
    static func parseFullName(_ displayName: String?) -> String? {
        guard let displayName else { return nil }
        let cleaned = displayName
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }

        if let comma = cleaned.firstIndex(of: ",") {
            let family = cleaned[..<comma].trimmingCharacters(in: .whitespaces)
            let given = cleaned[cleaned.index(after: comma)...]
                .trimmingCharacters(in: .whitespaces)
            if !family.isEmpty, !given.isEmpty {
                return normalizedCase("\(given) \(family)")
            }
        }
        return normalizedCase(cleaned)
    }

    /// Title-cases only the words the portal shouted. A name that already has
    /// deliberate capitalization — McDonald, van Dijk — is left alone.
    private static func normalizedCase(_ value: String) -> String {
        value
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { word in
                word
                    .split(separator: "-", omittingEmptySubsequences: false)
                    .map { part -> String in
                        let text = String(part)
                        guard text.count > 1, text == text.uppercased() else { return text }
                        return text.prefix(1).uppercased() + text.dropFirst().lowercased()
                    }
                    .joined(separator: "-")
            }
            .joined(separator: " ")
    }

    static func parseEvents(
        _ records: [PortalCalendarRecord],
        institution: Institution
    ) -> [PortalCalendarEvent] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = institution.timeZone

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = institution.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let rangeExpressions = Self.rangePatterns.compactMap {
            try? NSRegularExpression(pattern: $0)
        }
        let timeExpressions = Self.singleTimePatterns.compactMap {
            try? NSRegularExpression(pattern: $0)
        }

        var seen = Set<String>()

        return records.compactMap { record in
            guard let firstDay = dateFormatter.date(from: record.isoStartDate) else {
                return nil
            }

            let lastDay = record.isoEndDate
                .flatMap(dateFormatter.date(from:))
                ?? firstDay
            let title = normalize(record.title)
            guard !title.isEmpty else { return nil }

            let timeText = normalizeOptional(record.timeText)
            let parsedTime = timeText.flatMap {
                parseTime(
                    $0,
                    firstDay: firstDay,
                    lastDay: lastDay,
                    calendar: calendar,
                    rangeExpressions: rangeExpressions,
                    timeExpressions: timeExpressions
                )
            }

            let start = parsedTime?.start ?? calendar.startOfDay(for: firstDay)
            let end: Date?
            if let parsedTime {
                end = parsedTime.end
            } else if firstDay != lastDay {
                end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay))
            } else {
                end = nil
            }

            let category = category(for: record.categoryCode, conventions: institution.conventions)
            let subtitle = normalizeOptional(record.subtitle)
            let detail = normalizeOptional(record.detail)
            let location = normalizeOptional(record.location)
            let isAllDay = parsedTime == nil
            let links = parseLinks(record.links, origin: institution.origin)
            let community = parseLink(
                title: record.communityTitle,
                url: record.communityURL,
                origin: institution.origin
            )
            let identity = [
                category.rawValue,
                start.formatted(.iso8601),
                end?.formatted(.iso8601) ?? "",
                title,
                subtitle ?? "",
                location ?? ""
            ].joined(separator: "|")

            guard seen.insert(identity).inserted else { return nil }

            return PortalCalendarEvent(
                institutionID: institution.id,
                category: category,
                title: title,
                subtitle: subtitle,
                detail: detail,
                location: location,
                start: start,
                end: end,
                isAllDay: isAllDay,
                links: links,
                community: community
            )
        }
        .sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func parseUpdates(_ records: [PortalUpdateRecord]) -> [PortalUpdate] {
        var seen = Set<String>()

        return records.compactMap { record in
            guard
                let kind = PortalUpdate.Kind(rawValue: record.kind),
                // The general news feed is no longer shown. Filtering here as
                // well as at the scraper means a cache written before it was
                // dropped stops surfacing it too, without being discarded.
                kind != .news,
                !normalize(record.title).isEmpty
            else {
                return nil
            }

            let title = normalize(record.title)
            let detail = normalizeOptional(record.detail)
            let identity = [kind.rawValue, title, detail ?? ""].joined(separator: "|")
            guard seen.insert(identity).inserted else { return nil }

            return PortalUpdate(kind: kind, title: title, detail: detail)
        }
    }

    private static func category(
        for code: String,
        conventions: PortalConventions
    ) -> PortalCalendarEvent.Category {
        switch code.uppercased() {
        case conventions.classMeetingCategoryCode.uppercased(): .classMeeting
        case conventions.courseworkCategoryCode.uppercased(): .coursework
        case conventions.academicCategoryCode.uppercased(): .academic
        case conventions.communityCategoryCode.uppercased(): .community
        default: .other
        }
    }

    // MARK: - Links

    private static func parseLinks(
        _ records: [PortalLinkRecord]?,
        origin: URL
    ) -> [PortalLink] {
        guard let records else { return [] }
        var seen = Set<URL>()

        return records.compactMap { record in
            guard let link = parseLink(title: record.title, url: record.url, origin: origin) else {
                return nil
            }
            guard seen.insert(link.url).inserted else { return nil }
            return link
        }
    }

    /// Resolves one link, keeping only schemes that are safe to hand to the
    /// system. The portal writes relative hrefs for its own pages, so those are
    /// rebuilt against the school's origin rather than dropped.
    private static func parseLink(
        title: String?,
        url: String?,
        origin: URL
    ) -> PortalLink? {
        guard let url else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let resolved = URL(string: trimmed, relativeTo: origin)?.absoluteURL
        guard
            let resolved,
            let scheme = resolved.scheme?.lowercased(),
            ["http", "https", "mailto", "tel"].contains(scheme)
        else {
            return nil
        }

        return PortalLink(title: normalize(title ?? ""), url: resolved)
    }

    /// Time ranges, in the orders the portal writes them.
    ///
    /// The second pattern is the French build: OmniVox writes "19 h 00 à
    /// 21 h 00" there, sometimes dropping the minutes entirely ("19 h à 21 h").
    /// Without it a French portal yields events the app believes are all-day.
    private static let rangePatterns = [
        #"(?i)(\d{1,2}):(\d{2})\s*(?:à|a|to|–|—|-)\s*(\d{1,2}):(\d{2})"#,
        #"(?i)\b(\d{1,2})\s*h\s*(\d{2})?\s*(?:à|a|to|–|—|-)\s*(\d{1,2})\s*h\s*(\d{2})?"#
    ]

    /// A single start time.
    ///
    /// The French form insists on minutes, unlike the range form: a room code
    /// like "3H.19" would otherwise read as 3 o'clock. In a range the "à"
    /// settles it, so minutes can stay optional there.
    private static let singleTimePatterns = [
        #"(?i)(?:^|\s)(\d{1,2}):(\d{2})(?:\s|$)"#,
        #"(?i)(?:^|\s)(\d{1,2})\s*h\s*(\d{2})(?:\s|$)"#
    ]

    private static func parseTime(
        _ text: String,
        firstDay: Date,
        lastDay: Date,
        calendar: Calendar,
        rangeExpressions: [NSRegularExpression],
        timeExpressions: [NSRegularExpression]
    ) -> (start: Date, end: Date?)? {
        let fullRange = NSRange(text.startIndex..., in: text)

        for expression in rangeExpressions {
            guard
                let match = expression.firstMatch(in: text, range: fullRange),
                let startHour = integer(in: text, range: match.range(at: 1)),
                let endHour = integer(in: text, range: match.range(at: 3))
            else {
                continue
            }

            // Absent minutes mean o'clock, which is how "19 h à 21 h" reads.
            let startMinute = integer(in: text, range: match.range(at: 2)) ?? 0
            let endMinute = integer(in: text, range: match.range(at: 4)) ?? 0

            guard
                valid(hour: startHour, minute: startMinute),
                valid(hour: endHour, minute: endMinute),
                let start = calendar.date(
                    bySettingHour: startHour,
                    minute: startMinute,
                    second: 0,
                    of: firstDay
                ),
                var end = calendar.date(
                    bySettingHour: endHour,
                    minute: endMinute,
                    second: 0,
                    of: lastDay
                )
            else {
                continue
            }

            if end <= start, let nextDay = calendar.date(byAdding: .day, value: 1, to: end) {
                end = nextDay
            }
            return (start, end)
        }

        for expression in timeExpressions {
            guard
                let match = expression.firstMatch(in: text, range: fullRange),
                let hour = integer(in: text, range: match.range(at: 1)),
                let minute = integer(in: text, range: match.range(at: 2)),
                valid(hour: hour, minute: minute),
                let start = calendar.date(
                    bySettingHour: hour,
                    minute: minute,
                    second: 0,
                    of: firstDay
                )
            else {
                continue
            }
            return (start, nil)
        }

        return nil
    }

    private static func valid(hour: Int, minute: Int) -> Bool {
        (0 ..< 24).contains(hour) && (0 ..< 60).contains(minute)
    }

    private static func integer(in string: String, range: NSRange) -> Int? {
        guard let swiftRange = Range(range, in: string) else { return nil }
        return Int(string[swiftRange])
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalize(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
