import WidgetKit
import SwiftUI

/// The medium widget: one class, and what follows it.
///
/// A Home Screen glance answers one question — "where am I supposed to be?" —
/// so the class in focus gets the room and the countdown, and everything after
/// it is compressed into a single "then" line.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OmnivoxNeoUpNext", provider: ScheduleProvider()) { entry in
            UpNextView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground(appearance: entry.appearance)
                }
        }
        .configurationDisplayName("Up Next")
        .description("Your current or next class, and what follows it.")
        .supportedFamilies([.systemMedium])
    }
}

struct UpNextView: View {
    let entry: ScheduleEntry

    private var schedule: SharedSchedule? { entry.schedule }
    private var current: SharedCourse? { schedule?.current(at: entry.date) }
    private var next: SharedCourse? { schedule?.next(after: entry.date) }

    /// The class the widget is about: the one running now, otherwise the one
    /// coming up.
    private var focus: SharedCourse? { current ?? next }

    var body: some View {
        if let focus {
            VStack(alignment: .leading, spacing: 0) {
                header

                Spacer(minLength: 6)

                Text(focus.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                HStack(spacing: 6) {
                    Text(timeRange(focus))
                    if let location = focus.location, !location.isEmpty {
                        Text("·")
                        Text(location).fontWeight(.medium)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 6)

                thenLine
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            WidgetEmptyState(
                title: schedule == nil ? "Open Omnivox Neo" : "Nothing Left Today",
                message: schedule == nil
                    ? "Sign in once and your classes appear here."
                    : "No more classes scheduled.",
                accent: entry.accent
            )
        }
    }

    private var header: some View {
        ClassStatusStrip(current: current, next: next, accent: entry.accent)
    }

    @ViewBuilder
    private var thenLine: some View {
        // "What comes next" is the second half of the question. When a class is
        // running, the gap before the following one is the useful answer.
        if let current, let following = schedule?.next(after: current.end.addingTimeInterval(-1)) {
            let gap = following.start.timeIntervalSince(current.end)
            Label {
                Text(gap > 60
                     ? "\(durationText(gap)) break, then \(following.title)"
                     : "Then \(following.title)")
                    .lineLimit(1)
            } icon: {
                Image(systemName: gap > 60 ? "cup.and.saucer" : "arrow.right")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if current != nil {
            Label("Last class of the day", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if let next, let following = schedule?.next(after: next.start) {
            Label("Then \(following.title)", systemImage: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func timeRange(_ course: SharedCourse) -> String {
        "\(course.start.formatted(date: .omitted, time: .shortened))–\(course.end.formatted(date: .omitted, time: .shortened))"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder)"
    }
}

/// "Am I in class, and how long until that changes?" — the one line both
/// widgets open with.
///
/// Shared rather than duplicated so the two sizes can never drift into
/// disagreeing about the same moment. The countdown is a `.relative` `Text`,
/// which the system ticks on its own: no timeline entry per minute, and no
/// stale number between refreshes.
struct ClassStatusStrip: View {
    let current: SharedCourse?
    let next: SharedCourse?
    let accent: Color

    private var focus: SharedCourse? { current ?? next }

    var body: some View {
        if let focus {
            HStack(spacing: 5) {
                Circle()
                    .fill(current == nil ? accent : Color.green)
                    .frame(width: 6, height: 6)

                Text(current == nil ? "Up Next" : "In Class")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(current == nil ? accent : .green)

                Spacer(minLength: 4)

                // Counting to the end of the class in progress, otherwise to
                // the start of the one coming.
                Text(current == nil ? focus.start : focus.end, style: .relative)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct WidgetEmptyState: View {
    /// Keys, not Strings: passed as `String` the ternaries at the call sites
    /// resolved to `Text`'s verbatim initializer and shipped these lines in
    /// English on a French phone.
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(accent)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
