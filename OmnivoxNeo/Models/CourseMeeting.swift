import Foundation

struct CourseMeeting: Identifiable, Codable, Hashable, Sendable {
    let institutionID: String
    let title: String
    let courseLabel: String?
    let location: String?
    let start: Date
    let end: Date

    var id: String {
        [
            institutionID,
            start.formatted(.iso8601),
            end.formatted(.iso8601),
            title,
            courseLabel ?? "",
            location ?? ""
        ].joined(separator: "|")
    }

    var highlightStart: Date {
        start.addingTimeInterval(-ScheduleTimeline.highlightOffset)
    }

    var highlightEnd: Date {
        end.addingTimeInterval(-ScheduleTimeline.highlightOffset)
    }

    func isHighlighted(at date: Date) -> Bool {
        highlightStart <= date && date < highlightEnd
    }
}

struct ScheduleStatus: Equatable, Sendable {
    enum Kind: Sendable {
        case noClasses
        case beforeClass
        case classWindow
        case breakTime
        case finished
        case anotherDay
    }

    let kind: Kind
    let eyebrow: String
    let title: String
    let detail: String
    let systemImage: String
}

enum ScheduleTimeline {
    static let highlightOffset: TimeInterval = 15 * 60

    /// Main-actor because the copy is localized as it is built, and the app's
    /// chosen language is main-actor state. The alternative — returning keys
    /// for the view to resolve — would spread this one screen's wording across
    /// two files for no gain.
    @MainActor
    static func status(
        for meetings: [CourseMeeting],
        on selectedDay: Date,
        now: Date,
        calendar: Calendar
    ) -> ScheduleStatus {
        let dayMeetings = meetings
            .filter { calendar.isDate($0.start, inSameDayAs: selectedDay) }
            .sorted { $0.start < $1.start }

        guard !dayMeetings.isEmpty else {
            return ScheduleStatus(
                kind: .noClasses,
                eyebrow: Loc.text(calendar.isDateInToday(selectedDay) ? "Today" : "Schedule"),
                title: Loc.text("No classes"),
                detail: Loc.text("Nothing is scheduled."),
                systemImage: "sun.max.fill"
            )
        }

        guard calendar.isDate(selectedDay, inSameDayAs: now) else {
            let count = dayMeetings.count
            return ScheduleStatus(
                kind: .anotherDay,
                eyebrow: Loc.text("Schedule"),
                title: count == 1 ? Loc.text("1 class") : Loc.text("%lld classes", count),
                detail: dayMeetings.first?.title ?? "",
                systemImage: "calendar"
            )
        }

        if let active = dayMeetings.first(where: { $0.isHighlighted(at: now) }) {
            if now < active.start {
                return ScheduleStatus(
                    kind: .classWindow,
                    eyebrow: Loc.text("Up next"),
                    title: Loc.text("Starts in %@", countdown(from: now, to: active.start)),
                    detail: active.title,
                    systemImage: "figure.walk.motion"
                )
            }

            return ScheduleStatus(
                kind: .classWindow,
                eyebrow: Loc.text("In class"),
                title: Loc.text("Ends in %@", countdown(from: now, to: active.end)),
                detail: active.title,
                systemImage: "book.closed.fill"
            )
        }

        if let next = dayMeetings.first(where: { now < $0.highlightStart }) {
            let hasEarlierClass = dayMeetings.contains { $0.highlightEnd <= now }
            return ScheduleStatus(
                kind: hasEarlierClass ? .breakTime : .beforeClass,
                eyebrow: Loc.text(hasEarlierClass ? "Break" : "Up next"),
                title: hasEarlierClass
                    ? Loc.text("%@ break", countdown(from: now, to: next.highlightStart))
                    : Loc.text("Starts in %@", countdown(from: now, to: next.start)),
                detail: next.title,
                systemImage: hasEarlierClass ? "cup.and.heat.waves.fill" : "clock.fill"
            )
        }

        return ScheduleStatus(
            kind: .finished,
            eyebrow: Loc.text("All done"),
            title: Loc.text("Classes finished"),
            detail: Loc.text("That’s everything for today."),
            systemImage: "checkmark.circle.fill"
        )
    }

    @MainActor
    private static func countdown(from start: Date, to end: Date) -> String {
        let interval = max(0, end.timeIntervalSince(start))

        if interval >= 60 * 60 {
            let totalMinutes = Int(ceil(interval / 60))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return Loc.text("%lld h %@ min", hours, twoDigits(minutes))
        }

        // Keep the sub-hour format in the requested mm:ss shape at the hour boundary.
        let totalSeconds = min(Int(ceil(interval)), (60 * 60) - 1)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return Loc.text("%@ min %@ s", twoDigits(minutes), twoDigits(seconds))
    }

    private static func twoDigits(_ value: Int) -> String {
        String(format: "%02d", value)
    }
}
