import WidgetKit
import SwiftUI

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let schedule: SharedSchedule?
    let appearance: SharedAppearance?

    /// The appearance file wins: it is written the moment a colour is tapped,
    /// while the accent inside a schedule snapshot is only as fresh as the last
    /// portal refresh.
    var accent: Color {
        AccentChoice.named(appearance?.accentID ?? schedule?.accentID).color
    }
}

/// Supplies both widget sizes from the snapshot the app leaves in the shared
/// container.
///
/// The widget never talks to OmniVox. It has no session, no cookies and no
/// authenticator — it only renders what the app last wrote, which is also why
/// it keeps working when the student is offline.
struct ScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry {
        ScheduleEntry(date: Date(), schedule: .placeholder, appearance: SharedAppearance.load())
    }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        let schedule = context.isPreview ? .placeholder : SharedSchedule.load()
        // The gallery preview keeps the student's real colours — it is their
        // widget they are choosing, and the look is the point of the preview.
        completion(ScheduleEntry(
            date: Date(),
            schedule: schedule,
            appearance: SharedAppearance.load()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let now = Date()
        let schedule = SharedSchedule.load()
        let appearance = SharedAppearance.load()
        let entries = refreshPoints(from: now, schedule: schedule)
            .map { ScheduleEntry(date: $0, schedule: schedule, appearance: appearance) }

        // Ask for new data after the last point we planned for, or in an hour
        // if the day is already over.
        let nextRefresh = entries.last?.date.addingTimeInterval(60 * 30)
            ?? now.addingTimeInterval(60 * 60)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    /// Re-render when something actually changes — a class starting or ending —
    /// rather than on a fixed clock. A countdown also needs regular ticks, so
    /// quarter-hours are mixed in, and the whole list is capped because
    /// WidgetKit budgets how often it will wake us.
    private func refreshPoints(from now: Date, schedule: SharedSchedule?) -> [Date] {
        var points: Set<Date> = [now]

        if let schedule {
            let horizon = now.addingTimeInterval(60 * 60 * 12)
            for course in schedule.courses {
                for boundary in [course.start, course.end] where boundary > now && boundary < horizon {
                    points.insert(boundary)
                    // A moment after the boundary too, so the "now" state has
                    // definitely flipped by the time we draw.
                    points.insert(boundary.addingTimeInterval(1))
                }
            }
        }

        var tick = now
        for _ in 0..<12 {
            tick = tick.addingTimeInterval(60 * 15)
            points.insert(tick)
        }

        return Array(points.sorted().prefix(40))
    }
}

extension SharedSchedule {
    /// Used for the widget gallery and previews, where reading the real
    /// container is either unavailable or would show a stranger's schedule.
    static var placeholder: SharedSchedule {
        let now = Date()
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now

        return SharedSchedule(
            accountLabel: "Alex Tremblay",
            // Neutral on purpose: this is the picture in the widget gallery,
            // shown before anyone has signed in, and naming one college there
            // tells every other college's student the app is not for them.
            schoolName: "Your College",
            accentID: AccentChoice.blue.rawValue,
            updatedAt: now,
            courses: [
                SharedCourse(
                    title: "Calculus I",
                    courseLabel: "MAT-101",
                    location: "A-101",
                    start: start,
                    end: start.addingTimeInterval(90 * 60)
                ),
                SharedCourse(
                    title: "Thinking Critically",
                    courseLabel: "PHI-101",
                    location: "B-204",
                    start: start.addingTimeInterval(120 * 60),
                    end: start.addingTimeInterval(240 * 60)
                ),
                SharedCourse(
                    title: "Intro to College English",
                    courseLabel: "ENG-101",
                    location: "C-112",
                    start: start.addingTimeInterval(270 * 60),
                    end: start.addingTimeInterval(390 * 60)
                ),
                SharedCourse(
                    title: "Applied Research",
                    courseLabel: "SCI-210",
                    location: "D-330",
                    start: start.addingTimeInterval(420 * 60),
                    end: start.addingTimeInterval(510 * 60)
                )
            ]
        )
    }
}
