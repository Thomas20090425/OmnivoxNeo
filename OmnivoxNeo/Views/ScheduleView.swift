import SwiftUI

struct ScheduleView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var readState: AgendaReadState

    @State private var selectedDay = Date()
    @State private var showsAgenda = false

    init(model: AppModel) {
        self.model = model
        _readState = ObservedObject(wrappedValue: model.agendaReadState)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.institution.timeZone
        return calendar
    }

    /// The bell only exists where there is an agenda to open.
    private var showsAgendaButton: Bool {
        model.institution.has(.agenda)
    }

    /// What the badge counts: agenda entries that are genuinely new or have
    /// changed since this account last looked, measured against the copy kept
    /// from the previous refresh.
    ///
    /// It used to count everything happening in the next two days, which meant
    /// the dot was almost always lit and therefore said nothing. A badge is
    /// only worth having if its absence is also information.
    private var unreadCount: Int {
        model.agendaReadState.unreadCount
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        dayPicker

                        StatusHero(
                            status: ScheduleTimeline.status(
                                for: model.courses,
                                on: selectedDay,
                                now: timeline.date,
                                calendar: calendar
                            )
                        )

                        scheduleSection(now: timeline.date)

                        if let error = model.sessionError {
                            SessionErrorBanner(message: error)
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity)
                }
                .refreshable {
                    model.refreshSchedule()
                }
                // Cards and the day-picker circles are the surface colour, so
                // the page behind them has to be the grouped colour or they
                // disappear into a plain white background.
                .scrollContentBackground(.hidden)
                .background(NeoBackground())
                .navigationTitle(greeting(at: timeline.date))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.large)
                #endif
                .toolbar {
                    if showsAgendaButton {
                        ToolbarItem(placement: .primaryAction) {
                            agendaButton
                        }
                    }
                }
            }
            .sheet(isPresented: $showsAgenda) {
                AgendaView(model: model)
            }
        }
    }

    /// The bell, in the slot that was being kept for it.
    ///
    /// A badge rather than a number in the label: the count is a nudge, not
    /// information you act on, and it has to survive next to a long greeting
    /// without pushing the title around.
    private var agendaButton: some View {
        Button {
            showsAgenda = true
        } label: {
            Image(systemName: "bell.fill")
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -3)
                    }
                }
        }
        .accessibilityLabel("Agenda")
        .accessibilityValue(unreadCount > 0 ? Loc.text("%lld new or updated", unreadCount) : "")
    }

    // Day navigation stays inline, immediately under the title, leaving the
    // toolbar's trailing slot to the agenda bell.
    private var dayPicker: some View {
        HStack(spacing: 13) {
            Button {
                moveSelectedDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(Neo.surface, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous day")

            Button {
                withAnimation(.snappy) {
                    selectedDay = Date()
                }
            } label: {
                VStack(spacing: 2) {
                    Text(dayTitle(selectedDay))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(daySubtitle(selectedDay))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Return to today")

            Button {
                moveSelectedDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(Neo.surface, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next day")
        }
    }

    @ViewBuilder
    private func scheduleSection(now: Date) -> some View {
        let dayCourses = model.courses.filter {
            calendar.isDate($0.start, inSameDayAs: selectedDay)
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Schedule")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                if model.isRefreshingSchedule {
                    ProgressView()
                        .controlSize(.small)
                } else if let refreshed = model.lastScheduleRefresh {
                    Text("Updated \(relativeTime(refreshed, now: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if dayCourses.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.title)
                        .foregroundStyle(.tertiary)

                    Text("Nothing scheduled")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Enjoy the open space in your day.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .padding(.horizontal, 18)
                .neoCard()
            } else {
                ForEach(dayCourses) { meeting in
                    CourseCard(
                        meeting: meeting,
                        isHighlighted: calendar.isDateInToday(selectedDay) && meeting.isHighlighted(at: now),
                        timeZone: model.institution.timeZone
                    )
                }
            }
        }
    }

    private func moveSelectedDay(by value: Int) {
        guard let updated = calendar.date(byAdding: .day, value: value, to: selectedDay) else { return }
        withAnimation(.snappy) {
            selectedDay = updated
        }
    }

    // The day picker goes through `AgendaFormat` for the same reason the agenda
    // does: `DateFormatter` follows the device unless told otherwise, so a
    // French build would otherwise print "Bonjour, Thomas" above "Monday".
    private func dayTitle(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return Loc.text("Today") }
        if calendar.isDateInTomorrow(date) { return Loc.text("Tomorrow") }
        if calendar.isDateInYesterday(date) { return Loc.text("Yesterday") }
        return AgendaFormat.weekday(date, timeZone: model.institution.timeZone)
    }

    private func daySubtitle(_ date: Date) -> String {
        AgendaFormat.fullDate(date, timeZone: model.institution.timeZone)
    }

    private func relativeTime(_ date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return Loc.text("just now") }
        return Loc.text("%lldm ago", Int(elapsed / 60))
    }

    /// The title of the whole screen, so it goes through `Loc` rather than
    /// being a plain Swift string: `navigationTitle` takes a `String` here —
    /// the name is interpolated into it — and a plain string is never
    /// localized. Each greeting is therefore a format, not a sentence built by
    /// gluing a salutation to a comma, which lets a translation move the name.
    private func greeting(at date: Date) -> String {
        let hour = calendar.component(.hour, from: date)
        guard let firstName = model.userFirstName, !firstName.isEmpty else {
            return Loc.text(Self.anonymousGreetingKey(for: hour))
        }
        return Loc.text(Self.greetingKey(for: hour), firstName)
    }

    /// Small hours get their own greeting. "Good Morning" at 3am is technically
    /// true and reads as a machine that has not looked out of the window.
    private static func greetingKey(for hour: Int) -> String {
        switch hour {
        case ..<5: "Hey, Night Owl %@"
        case ..<12: "Good Morning, %@"
        case ..<18: "Good Afternoon, %@"
        default: "Good Evening, %@"
        }
    }

    private static func anonymousGreetingKey(for hour: Int) -> String {
        switch hour {
        case ..<5: "Hey, Night Owl"
        case ..<12: "Good Morning"
        case ..<18: "Good Afternoon"
        default: "Good Evening"
        }
    }
}

private struct StatusHero: View {
    let status: ScheduleStatus

    /// The hero follows the student's accent.
    ///
    /// It is the largest block of colour on the screen, so leaving it on a
    /// fixed palette was what made picking an accent feel like it did nothing.
    /// The state is already spelled out by the icon and the eyebrow — "In
    /// class", "Break", "All done" — so the hue was saying it a second time,
    /// and can carry identity instead.
    private var base: Color { Neo.accent }

    /// A running class is the one state worth marking in colour, because it is
    /// the one the student has not been told about in words yet when they
    /// glance. Everything else takes the accent straight.
    private var isLive: Bool { status.kind == .classWindow }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 64, height: 64)

                Image(systemName: status.systemImage)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(status.eyebrow.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.88))

                Text(status.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())

                Text(status.detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [
                    base.mix(with: .black, by: 0.28),
                    base.mix(with: .black, by: 0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 25, style: .continuous)
        )
        .overlay {
            // A thin live ring instead of a whole second hue: it reads at a
            // glance without competing with the accent underneath.
            if isLive {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .strokeBorder(Neo.live, lineWidth: 2)
            }
        }
        .shadow(color: base.opacity(0.28), radius: 20, y: 10)
        .accessibilityElement(children: .combine)
    }
}

private struct CourseCard: View {
    let meeting: CourseMeeting
    let isHighlighted: Bool
    let timeZone: TimeZone

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(time(meeting.start))
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(.primary)

                Capsule()
                    .fill(isHighlighted ? Neo.live : Neo.accent.opacity(0.22))
                    .frame(width: 3, height: 28)

                Text(time(meeting.end))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 66)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meeting.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isHighlighted {
                        Text("NOW")
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Neo.live.opacity(0.35), in: Capsule())
                    }
                }

                if let label = meeting.courseLabel {
                    Label(label, systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let location = meeting.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(isHighlighted ? Neo.accent : .secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            isHighlighted ? Neo.live.opacity(0.14) : Neo.surface,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isHighlighted ? Neo.live : Neo.separator, lineWidth: isHighlighted ? 2 : 1)
        }
        .shadow(
            color: isHighlighted ? Neo.live.opacity(0.22) : .black.opacity(0.12),
            radius: isHighlighted ? 18 : 13,
            y: 7
        )
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
        .accessibilityElement(children: .combine)
    }

    /// Shared with the agenda so both obey the app's language — a French build
    /// wants 14:00, not 2:00 PM.
    private func time(_ date: Date) -> String {
        AgendaFormat.time(date, timeZone: timeZone)
    }
}
