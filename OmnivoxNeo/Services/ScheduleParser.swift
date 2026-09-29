import Foundation

struct PortalCourseRecord: Codable, Hashable, Sendable {
    let isoDate: String
    let title: String
    let timeRange: String
    let courseLabel: String?
    let location: String?
}

enum ScheduleParser {
    static func parse(
        _ records: [PortalCourseRecord],
        institution: Institution
    ) -> [CourseMeeting] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = institution.timeZone

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = institution.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let rangeExpression = try? NSRegularExpression(
            pattern: #"(?i)(\d{1,2}):(\d{2})\s*(?:à|a|to|–|—|-)\s*(\d{1,2}):(\d{2})"#
        )

        var seen = Set<String>()

        return records.compactMap { record in
            guard
                let day = dateFormatter.date(from: record.isoDate),
                let rangeExpression,
                let match = rangeExpression.firstMatch(
                    in: record.timeRange,
                    range: NSRange(record.timeRange.startIndex..., in: record.timeRange)
                ),
                let startHour = integer(in: record.timeRange, range: match.range(at: 1)),
                let startMinute = integer(in: record.timeRange, range: match.range(at: 2)),
                let endHour = integer(in: record.timeRange, range: match.range(at: 3)),
                let endMinute = integer(in: record.timeRange, range: match.range(at: 4)),
                startHour < 24,
                endHour < 24,
                startMinute < 60,
                endMinute < 60,
                let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: day),
                var end = calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: day)
            else {
                return nil
            }

            if end <= start, let nextDay = calendar.date(byAdding: .day, value: 1, to: end) {
                end = nextDay
            }

            guard start < end else { return nil }

            let normalizedTitle = normalize(record.title)
            guard !normalizedTitle.isEmpty else { return nil }

            let normalizedLabel = normalizeOptional(record.courseLabel)
            let normalizedLocation = normalizeOptional(record.location)
            let identity = [
                record.isoDate,
                String(startHour),
                String(startMinute),
                String(endHour),
                String(endMinute),
                normalizedTitle,
                normalizedLabel ?? "",
                normalizedLocation ?? ""
            ].joined(separator: "|")

            guard seen.insert(identity).inserted else { return nil }

            return CourseMeeting(
                institutionID: institution.id,
                title: normalizedTitle,
                courseLabel: normalizedLabel,
                location: normalizedLocation,
                start: start,
                end: end
            )
        }
        .sorted { $0.start < $1.start }
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
