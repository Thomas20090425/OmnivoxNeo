import SwiftUI

/// Everything dated that is not a class: coursework, deadlines, campus life.
///
/// Presented from the bell on Home rather than living in the tab bar. It answers
/// "what is coming up", which is a question a student asks occasionally — not
/// one worth a permanent fifth of the screen's bottom edge.
///
/// Laid out as a month, because that is the shape the information already has.
/// The previous version printed every event in one continuous column, which is
/// technically complete and impossible to scan: you could not tell a free week
/// from a busy one without reading it.
struct AgendaView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var model: AppModel
    @ObservedObject private var readState: AgendaReadState
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _readState = ObservedObject(wrappedValue: model.agendaReadState)
    }

    @State private var selectedDay: Date = .now
    @State private var visibleMonth: Date = .now
    @State private var enabledCategories = Set(PortalCalendarEvent.Category.agendaCategories)
    @State private var selectedEvent: PortalCalendarEvent?
    @State private var showsCalendarSync = false

    private var conventions: PortalConventions { model.institution.conventions }

    /// The school's time zone, but the student's language.
    ///
    /// The locale matters as much as the zone here: it is what gives the grid
    /// French weekday initials and starts the week on the right day. Leaving it
    /// at the device default meant a French build still printed "S M T W T F S".
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = model.institution.timeZone
        calendar.locale = AppLanguageStore.shared.locale
        return calendar
    }

    /// The agenda's own slice of the portal: classes are excluded outright,
    /// then the student's category filters apply on top.
    private var events: [PortalCalendarEvent] {
        model.calendarEvents.filter {
            $0.category.belongsInAgenda && enabledCategories.contains($0.category)
        }
    }

    private var index: AgendaIndex {
        AgendaIndex(events: events, calendar: calendar)
    }

    private var updates: [PortalUpdate] {
        model.portalUpdates.filter { $0.kind == .whatsNew }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let index = index

                LazyVStack(alignment: .leading, spacing: 22) {
                    if let error = model.sessionError {
                        SessionErrorBanner(message: error)
                    }

                    unreadBanner
                    whatsNewSection

                    MonthCalendar(
                        month: visibleMonth,
                        selectedDay: selectedDay,
                        calendar: calendar,
                        timeZone: model.institution.timeZone,
                        categoriesByDay: index.categoriesByDay,
                        unreadByDay: unreadCounts(in: index),
                        onSelect: select,
                        onStepMonth: stepMonth
                    )

                    categoryFilters

                    daySection(index: index)
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity)
            }
            .refreshable { model.refreshSchedule() }
            .scrollContentBackground(.hidden)
            .background(NeoBackground())
            .navigationTitle("Agenda")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsCalendarSync = true
                    } label: {
                        Image(systemName: "calendar.badge.plus")
                    }
                    .accessibilityLabel("Calendar subscription")
                }
            }
            .sheet(item: $selectedEvent) { event in
                AgendaEventDetailView(event: event, institution: model.institution)
            }
            .sheet(isPresented: $showsCalendarSync) {
                CalendarSyncSettingsView(model: model)
            }
        }
        .task {
            // Open on today, in today's month, however long the sheet has been
            // closed. Opening on a stale day is the kind of small wrongness
            // that makes an app feel abandoned.
            let today = Date()
            selectedDay = today
            visibleMonth = today
        }
        // Only the day still on screen, not the whole agenda. Closing the
        // sheet used to clear everything, which made the per-day badges
        // pointless — one visit and every day you never opened was "read".
        .onDisappear { markSelectedDayRead() }
    }

    // MARK: - Unread

    /// Says how much changed and offers to clear it in one tap.
    ///
    /// Present only when there is something to say: a permanent "0 new" row
    /// would be a control that is almost always a no-op.
    @ViewBuilder
    private var unreadBanner: some View {
        if readState.hasUnread {
            HStack(spacing: 10) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)

                Text("^[\(readState.unreadCount) item](inflect: true) new or updated")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Button("Mark All as Read") {
                    withAnimation(.snappy(duration: 0.2)) {
                        readState.markAllRead()
                    }
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Neo.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neoCard()
        }
    }

    // MARK: - What's new

    @ViewBuilder
    private var whatsNewSection: some View {
        if !updates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("New Since Your Last Visit", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(updates.enumerated()), id: \.element.id) { offset, update in
                        if offset > 0 { Divider().padding(.leading, 16) }
                        WhatsNewRow(update: update)
                    }
                }
                .neoCard()
            }
        }
    }

    // MARK: - Filters

    /// Toggles rather than a segmented control, because these are not exclusive
    /// — a student watching for deadlines and coursework at once is the normal
    /// case. Each carries the colour its dots use in the grid above, so the row
    /// doubles as the legend.
    private var categoryFilters: some View {
        HStack(spacing: 8) {
            ForEach(PortalCalendarEvent.Category.agendaCategories, id: \.self) { category in
                let isOn = enabledCategories.contains(category)

                Button {
                    toggle(category)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(category.tint)
                            .frame(width: 8, height: 8)
                            .opacity(isOn ? 1 : 0.35)

                        category.label(conventions)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(isOn ? .primary : .secondary)
                            .lineLimit(1)
                            // "Academic Calendar" is the longest label and the
                            // one that must not truncate — a chip reading
                            // "Academic Cale…" is a filter you have to guess at.
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        isOn ? category.tint.opacity(0.14) : Color.clear,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule().strokeBorder(
                            isOn ? category.tint.opacity(0.45) : Neo.separator,
                            lineWidth: 1
                        )
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    /// Unread counts per day, so the grid can mark exactly the days that
    /// changed rather than every day that has anything on it.
    private func unreadCounts(in index: AgendaIndex) -> [Date: Int] {
        guard readState.hasUnread else { return [:] }
        return index.byDay.reduce(into: [:]) { result, entry in
            let count = readState.unreadCount(among: entry.value)
            if count > 0 { result[entry.key] = count }
        }
    }

    // MARK: - The selected day

    @ViewBuilder
    private func daySection(index: AgendaIndex) -> some View {
        let day = calendar.startOfDay(for: selectedDay)
        let dayEvents = index.byDay[day] ?? []

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(AgendaFormat.dayHeading(day, calendar: calendar, timeZone: model.institution.timeZone))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                if case let unread = readState.unreadCount(among: dayEvents), unread > 0 {
                    UnreadBadge(count: unread)
                }

                Spacer(minLength: 8)

                if model.isRefreshingSchedule {
                    ProgressView().controlSize(.small)
                }
            }

            if dayEvents.isEmpty {
                emptyDay(after: day, index: index)
            } else {
                VStack(spacing: 10) {
                    ForEach(dayEvents) { event in
                        Button {
                            selectedEvent = event
                        } label: {
                            AgendaEventRow(
                                event: event,
                                day: day,
                                isUnread: readState.isUnread(event),
                                conventions: conventions,
                                calendar: calendar,
                                timeZone: model.institution.timeZone
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows event details")
                    }
                }
            }
        }
    }

    /// An empty day says what is next rather than just saying "nothing", so the
    /// student does not have to tap through the month hunting for the next
    /// thing that matters.
    @ViewBuilder
    private func emptyDay(after day: Date, index: AgendaIndex) -> some View {
        let upcoming = index.nextDay(after: day)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.tertiary)

                Text("Nothing on this day")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let upcoming, let next = index.byDay[upcoming]?.first {
                Divider()

                Button {
                    select(upcoming)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(next.category.tint)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next: \(next.title)")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(AgendaFormat.dayHeading(
                                upcoming,
                                calendar: calendar,
                                timeZone: model.institution.timeZone
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }

    // MARK: - Actions

    private func select(_ day: Date) {
        // The day being left is the one that has been looked at, so its badge
        // clears as the student moves on. Clearing on arrival instead would
        // take the highlight away while they were still reading the day it
        // was pointing at.
        if !calendar.isDate(day, inSameDayAs: selectedDay) {
            markSelectedDayRead()
        }
        withAnimation(.snappy(duration: 0.2)) {
            selectedDay = day
            if !calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month) {
                visibleMonth = day
            }
        }
    }

    /// Acknowledges whatever is on the day currently shown below the grid.
    private func markSelectedDayRead() {
        let day = calendar.startOfDay(for: selectedDay)
        // Read from the unfiltered set: a category the student has toggled off
        // is still on the day they just looked at, and leaving it unread would
        // make the badge reappear the moment the filter came back on.
        let dayEvents = AgendaIndex(
            events: model.calendarEvents.filter(\.category.belongsInAgenda),
            calendar: calendar
        ).byDay[day] ?? []
        readState.markRead(dayEvents)
    }

    private func stepMonth(_ delta: Int) {
        guard let moved = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else {
            return
        }
        withAnimation(.snappy(duration: 0.2)) {
            visibleMonth = moved
        }
    }

    private func toggle(_ category: PortalCalendarEvent.Category) {
        withAnimation(.snappy(duration: 0.15)) {
            if enabledCategories.contains(category) {
                // Never leave the grid completely blank: turning the last
                // filter off looks identical to the portal having no data.
                if enabledCategories.count > 1 {
                    enabledCategories.remove(category)
                }
            } else {
                enabledCategories.insert(category)
            }
        }
    }
}

// MARK: - Day index

/// The agenda arranged by day, built once per render pass.
///
/// Multi-day events occupy every day they span, which is the whole point of
/// drawing a month: an exhibition that runs Monday to Thursday should be
/// visible on Wednesday, not only on the day it opened.
struct AgendaIndex {
    /// A ceiling on how many days one event may occupy. A portal entry with a
    /// malformed end date would otherwise paint the entire grid.
    private static let maximumSpan = 60

    private(set) var byDay: [Date: [PortalCalendarEvent]] = [:]
    private(set) var categoriesByDay: [Date: Set<PortalCalendarEvent.Category>] = [:]

    init(events: [PortalCalendarEvent], calendar: Calendar) {
        for event in events {
            for day in Self.days(of: event, calendar: calendar) {
                byDay[day, default: []].append(event)
                categoriesByDay[day, default: []].insert(event.category)
            }
        }

        for (day, list) in byDay {
            byDay[day] = list.sorted { left, right in
                if left.isAllDay != right.isAllDay { return left.isAllDay && !right.isAllDay }
                if left.start != right.start { return left.start < right.start }
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
        }
    }

    func nextDay(after day: Date) -> Date? {
        byDay.keys.filter { $0 > day }.min()
    }

    private static func days(
        of event: PortalCalendarEvent,
        calendar: Calendar
    ) -> [Date] {
        let first = calendar.startOfDay(for: event.start)

        // An all-day span ends at the start of the following day, so a second
        // is taken off before asking which day that is.
        guard let rawEnd = event.end else { return [first] }
        let lastMoment = event.isAllDay ? rawEnd.addingTimeInterval(-1) : rawEnd
        let last = calendar.startOfDay(for: max(lastMoment, event.start))

        guard last > first else { return [first] }

        var days = [first]
        var cursor = first
        while cursor < last, days.count < maximumSpan {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            days.append(next)
            cursor = next
        }
        return days
    }
}

// MARK: - Month grid

private struct MonthCalendar: View {
    let month: Date
    let selectedDay: Date
    let calendar: Calendar
    let timeZone: TimeZone
    let categoriesByDay: [Date: Set<PortalCalendarEvent.Category>]
    let unreadByDay: [Date: Int]
    let onSelect: (Date) -> Void
    let onStepMonth: (Int) -> Void

    private var days: [Date] {
        guard
            let monthInterval = calendar.dateInterval(of: .month, for: month),
            let gridStart = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)?.start
        else {
            return []
        }

        // Six weeks always: a grid that changes height as you page months
        // makes the content below it jump around.
        return (0 ..< 42).compactMap {
            calendar.date(byAdding: .day, value: $0, to: gridStart)
        }
    }

    /// Starts at the locale's first weekday, so a French build starts on Monday
    /// without a second list of strings.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    DayCell(
                        day: day,
                        isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                        isToday: calendar.isDateInToday(day),
                        isInMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                        categories: categoriesByDay[calendar.startOfDay(for: day)] ?? [],
                        unreadCount: unreadByDay[calendar.startOfDay(for: day)] ?? 0,
                        calendar: calendar,
                        timeZone: timeZone,
                        onSelect: onSelect
                    )
                }
            }
            // Swiping the grid is how a calendar is expected to move. The arrows
            // stay, because a gesture nobody discovers is not a control.
            //
            // `minimumDistance` is deliberately generous: this sits inside a
            // vertical ScrollView, and a low threshold turns every slightly
            // slanted scroll into a month change.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        guard abs(horizontal) > abs(value.translation.height) else { return }
                        onStepMonth(horizontal < 0 ? 1 : -1)
                    }
            )
        }
        .padding(16)
        .neoCard()
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(AgendaFormat.monthHeading(month, calendar: calendar, timeZone: timeZone))
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Button { onStepMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")

            Button { onSelect(Date()) } label: {
                Text("Today")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 4)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { onStepMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next month")
        }
    }
}

private struct DayCell: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let isInMonth: Bool
    let categories: Set<PortalCalendarEvent.Category>
    let unreadCount: Int
    let calendar: Calendar
    let timeZone: TimeZone
    let onSelect: (Date) -> Void

    /// Ordered so the same category always sits in the same position, which is
    /// what lets the dots be read as a pattern rather than re-parsed each time.
    private var dots: [PortalCalendarEvent.Category] {
        PortalCalendarEvent.Category.agendaCategories.filter(categories.contains)
    }

    var body: some View {
        Button {
            onSelect(day)
        } label: {
            VStack(spacing: 3) {
                Text(AgendaFormat.dayNumber(day, timeZone: timeZone))
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                    .frame(width: 32, height: 32)
                    .background {
                        if isSelected {
                            Circle().fill(Neo.accent)
                        } else if isToday {
                            Circle().strokeBorder(Neo.accent, lineWidth: 1.5)
                        }
                    }
                    // Sits on the day number the way a badge sits on an app
                    // icon, so "this day changed" reads without being confused
                    // with the category dots underneath.
                    .overlay(alignment: .topTrailing) {
                        if unreadCount > 0 {
                            UnreadBadge(count: unreadCount, isCompact: true)
                                .offset(x: 7, y: -3)
                        }
                    }

                HStack(spacing: 3) {
                    ForEach(dots, id: \.self) { category in
                        Circle()
                            .fill(category.tint)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .opacity(isInMonth ? 1 : 0.32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return Neo.accent }
        return .primary
    }

    private var accessibilityLabel: String {
        let date = AgendaFormat.fullDate(day, timeZone: timeZone)
        guard unreadCount > 0 else {
            return dots.isEmpty ? date : "\(date), \(dots.count)"
        }
        return "\(date), " + Loc.text("%lld new or updated", unreadCount)
    }
}

// MARK: - Rows

private struct AgendaEventRow: View {
    let event: PortalCalendarEvent
    let day: Date
    let isUnread: Bool
    let conventions: PortalConventions
    let calendar: Calendar
    let timeZone: TimeZone

    /// A multi-day event shown on a day it did not start on says so, rather
    /// than repeating a start time that has already passed.
    private var isContinuation: Bool {
        !calendar.isDate(event.start, inSameDayAs: day)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.category.tint)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if isUnread {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                    }

                    event.category.label(conventions)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(event.category.tint)

                    Text(timeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(event.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                if let subtitle = event.subtitle, subtitle != event.title {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if let location = event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !event.links.isEmpty {
                    // `inflect` lets the system agree the noun with the number,
                    // in whichever language it ends up rendering.
                    Label(
                        "^[\(event.links.count) link](inflect: true)",
                        systemImage: "link"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        if isContinuation { return Loc.text("Continues") }
        if event.isAllDay { return Loc.text("All day") }

        let start = AgendaFormat.time(event.start, timeZone: timeZone)
        guard let end = event.end, !calendar.isDate(end, equalTo: event.start, toGranularity: .minute) else {
            return start
        }
        return "\(start) – \(AgendaFormat.time(end, timeZone: timeZone))"
    }
}

/// A count of unread items, in the one place the app uses red for emphasis
/// rather than for danger — matched to the system's own badge shape so it is
/// not mistaken for an error.
private struct UnreadBadge: View {
    let count: Int
    var isCompact = false

    var body: some View {
        Text("\(count)")
            .font(isCompact ? .system(size: 10, weight: .bold) : .caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, isCompact ? 4 : 6)
            .frame(minWidth: isCompact ? 16 : 20, minHeight: isCompact ? 16 : 20)
            .background(.red, in: Capsule())
            .accessibilityHidden(true)
    }
}

private struct WhatsNewRow: View {
    let update: PortalUpdate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(update.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                if let detail = update.detail, detail != update.title {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting

/// Dates written the way the app's chosen language writes them.
///
/// `Date.formatted()` follows the device, so it would keep printing English
/// dates under a French build the moment the student overrides the language
/// in-app. Everything here goes through that choice instead.
@MainActor
enum AgendaFormat {
    static func dayHeading(_ date: Date, calendar: Calendar, timeZone: TimeZone) -> String {
        if calendar.isDateInToday(date) { return Loc.text("Today") }
        if calendar.isDateInTomorrow(date) { return Loc.text("Tomorrow") }
        if calendar.isDateInYesterday(date) { return Loc.text("Yesterday") }
        return formatted(date, template: "EEEEdMMMM", timeZone: timeZone)
    }

    static func monthHeading(_ date: Date, calendar: Calendar, timeZone: TimeZone) -> String {
        formatted(date, template: "yMMMM", timeZone: timeZone)
    }

    static func fullDate(_ date: Date, timeZone: TimeZone) -> String {
        formatted(date, template: "EEEEdMMMMy", timeZone: timeZone)
    }

    static func shortDate(_ date: Date, timeZone: TimeZone) -> String {
        formatted(date, template: "dMMM", timeZone: timeZone)
    }

    static func time(_ date: Date, timeZone: TimeZone) -> String {
        formatted(date, template: "jmm", timeZone: timeZone)
    }

    static func dayNumber(_ date: Date, timeZone: TimeZone) -> String {
        formatted(date, template: "d", timeZone: timeZone)
    }

    static func weekday(_ date: Date, timeZone: TimeZone) -> String {
        formatted(date, template: "EEEE", timeZone: timeZone)
    }

    /// A template rather than a literal pattern, so the *order* of the parts is
    /// chosen by the locale — "September 22" in English, "22 septembre" in
    /// French, from the same call.
    private static func formatted(
        _ date: Date,
        template: String,
        timeZone: TimeZone
    ) -> String {
        let locale = AppLanguageStore.shared.locale
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
