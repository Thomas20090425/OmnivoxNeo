import WidgetKit
import SwiftUI

/// The large widget: the whole day at once.
///
/// Widgets cannot scroll, so the list adapts instead — a light day gets roomy
/// rows with course codes, a heavy one tightens up and drops the detail rather
/// than truncating the list. Anything that still will not fit is counted in a
/// footer so the day never silently appears shorter than it is.
struct DayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OmnivoxNeoDay", provider: ScheduleProvider()) { entry in
            DayView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground(appearance: entry.appearance)
                }
        }
        .configurationDisplayName("Today’s Classes")
        .description("Every class today, with the one in progress highlighted.")
        .supportedFamilies([.systemLarge])
    }
}

struct DayView: View {
    let entry: ScheduleEntry
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var compactRowHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var regularRowHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .headline) private var headerAndStatusHeight: CGFloat = 62
    @ScaledMetric(relativeTo: .caption2) private var overflowHeight: CGFloat = 20

    /// An expanded widget can use more of its height, while a compact pane or
    /// larger text must leave room for the status and overflow count.
    private static let maxRows = 8

    private var schedule: SharedSchedule? { entry.schedule }

    private var todaysCourses: [SharedCourse] {
        schedule?.courses(on: entry.date) ?? []
    }

    /// Scoped to today rather than to the schedule as a whole: a countdown to
    /// tomorrow's first class under a "Today" heading would be answering a
    /// question nobody asked.
    private var currentCourse: SharedCourse? {
        todaysCourses.first { $0.start <= entry.date && entry.date < $0.end }
    }

    private var nextCourse: SharedCourse? {
        todaysCourses.first { $0.start > entry.date }
    }

    var body: some View {
        GeometryReader { geometry in
            content(in: geometry.size)
        }
    }

    private func content(in available: CGSize) -> some View {
        // WidgetKit can offer different heights across the outer display,
        // inner display, and its resized layouts. Budget rows from the space
        // actually available instead of assuming every large widget is equal.
        let isCompact = todaysCourses.count > 4
            || available.height < 290
            || dynamicTypeSize.isAccessibilitySize
        let rowHeight = isCompact ? compactRowHeight : regularRowHeight
        let rowBudget = max(1, Int(max(0, available.height - headerAndStatusHeight - overflowHeight) / rowHeight))
        let visible = Array(todaysCourses.prefix(min(Self.maxRows, rowBudget)))
        let hidden = max(0, todaysCourses.count - visible.count)

        return VStack(alignment: .leading, spacing: 0) {
            header(isCompact: isCompact)

            ClassStatusStrip(
                current: currentCourse,
                next: nextCourse,
                accent: entry.accent
            )
            .padding(.top, 3)

            if visible.isEmpty {
                Spacer()
                WidgetEmptyState(
                    title: schedule == nil ? "Open Omnivox Neo" : "No Classes Today",
                    message: schedule == nil
                        ? "Sign in once and your classes appear here."
                        : "Enjoy the open space in your day.",
                    accent: entry.accent
                )
                Spacer()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, course in
                        if index > 0 { Divider().opacity(0.4) }
                        row(for: course, isCompact: isCompact)
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 0)

                if hidden > 0 {
                    // Each count is its own key rather than a noun glued on
                    // at the end: interpolating the word made the whole thing
                    // a `String`, so nothing here translated.
                    Text(hidden == 1
                         ? "+\(hidden) more class"
                         : "+\(hidden) more classes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func header(isCompact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.date.formatted(.dateTime.weekday(.wide)))
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Text(entry.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if !isCompact, let accountLabel = schedule?.accountLabel, !accountLabel.isEmpty {
                Text(accountLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func row(for course: SharedCourse, isCompact: Bool) -> some View {
        let isNow = course.start <= entry.date && entry.date < course.end
        let isPast = course.end <= entry.date

        return HStack(spacing: 10) {
            // The rail marks the running class without needing a second colour
            // anywhere else in the row.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(isNow ? Color.green : entry.accent.opacity(isPast ? 0.2 : 0.45))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(course.title)
                    .font(.subheadline.weight(isNow ? .semibold : .regular))
                    .foregroundStyle(isPast ? .secondary : .primary)
                    .lineLimit(1)

                if !isCompact, let label = course.courseLabel, !label.isEmpty {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text(course.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(isPast ? .tertiary : .secondary)
                    .fixedSize(horizontal: true, vertical: false)

                if !dynamicTypeSize.isAccessibilitySize,
                   let location = course.location, !location.isEmpty {
                    Text(location)
                        .font(.caption2)
                        .foregroundStyle(isPast ? .tertiary : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, isCompact ? 4 : 6)
        .opacity(isPast ? 0.55 : 1)
    }
}
