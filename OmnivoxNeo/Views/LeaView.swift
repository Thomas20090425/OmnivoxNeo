import SwiftUI

/// Somewhere a course card can send you.
///
/// A value rather than a view, because on a big screen the destination is not
/// pushed at all — it is what the other half of the window is showing, and a
/// column cannot be driven by a `NavigationLink` that already holds its own
/// answer. Phones use the same values and simply push them.
enum LeaRoute: Hashable {
    case course(LeaCourse)
    case documents(LeaCourse)
    case assignments(LeaCourse)
    case grades(LeaCourse)
    case announcement(LeaCourse, LeaAnnouncementSummary)

    var course: LeaCourse {
        switch self {
        case .course(let course),
             .documents(let course),
             .assignments(let course),
             .grades(let course),
             .announcement(let course, _):
            course
        }
    }
}

/// The Léa tab: one term's worth of classes, as a stream.
///
/// Deliberately no class filter. Léa's own page has one, but the app already
/// shows every course as its own card in schedule order — a filter would be a
/// control for hiding the thing the screen exists to show. The term picker
/// stays, because a term is a different set of courses rather than a subset of
/// this one.
struct LeaView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: LeaStore

    /// Which course cards have their summary open. Empty at launch: the cards
    /// start folded so the whole term fits on one screen.
    @State private var expanded: Set<String> = []
    /// What the other column is showing, where there is one.
    @State private var selected: LeaRoute?
    @State private var columns: NavigationSplitViewVisibility = .doubleColumn

    @Environment(\.prefersSplitLayout) private var prefersSplitLayout

    var body: some View {
        Group {
            if prefersSplitLayout {
                splitBody
            } else {
                stackBody
            }
        }
        .task { store.loadIfNeeded() }
    }

    // MARK: - One column, or two

    private var stackBody: some View {
        NavigationStack {
            stream
                .navigationDestination(for: LeaRoute.self) { route in
                    destination(for: route)
                }
        }
    }

    /// The same stream, kept at phone width, with whatever it points at open
    /// beside it.
    ///
    /// Léa is where a student goes to look something up mid-class: what the
    /// homework was, what they got, which handout. On an iPad that meant
    /// opening a course, reading one line, going back, opening the next — and
    /// the list of courses vanishing each time. Side by side, the looking-up
    /// happens without ever losing the place you were looking from.
    private var splitBody: some View {
        NavigationSplitView(columnVisibility: $columns) {
            stream
                .navigationSplitViewColumnWidth(
                    min: SplitColumn.minWidth,
                    ideal: SplitColumn.idealWidth,
                    max: SplitColumn.maxWidth
                )
        } detail: {
            NavigationStack {
                if let selected {
                    destination(for: selected)
                        .id(selected)
                } else {
                    noSelection
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // A different term is a different set of courses, so what was open is
        // no longer one of them.
        .onChange(of: store.selectedTerm) { selected = nil }
    }

    private var stream: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                termChip
                content
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity)
        }
        .refreshable { store.refresh() }
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle(model.institution.conventions.courseworkDisplayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        // The same menu, hung off the title itself, so the term is still
        // switchable once the chip has scrolled away under the collapsed
        // navigation bar.
        .toolbarTitleMenu { termMenuItems }
    }

    private var noSelection: some View {
        ZStack {
            NeoBackground()
            ContentUnavailableView(
                "Nothing Open",
                systemImage: "books.vertical",
                description: Text("Pick a class on the left to see it here.")
            )
        }
    }

    /// Where each of a card's rows goes. One place, so a phone pushing it and
    /// an iPad showing it beside the list cannot drift apart.
    @ViewBuilder
    private func destination(for route: LeaRoute) -> some View {
        switch route {
        case .course(let course):
            LeaCourseView(model: model, store: store, course: course)
        case .documents(let course):
            LeaDocumentsView(store: store, course: course)
        case .assignments(let course):
            LeaAssignmentsView(model: model, store: store, course: course)
        case .grades(let course):
            LeaGradesView(store: store, course: course)
        case .announcement(let course, let summary):
            if summary.url != nil {
                LeaAnnouncementView(
                    store: store,
                    summary: summary,
                    tint: store.identity(for: course).start
                )
            } else {
                LeaCourseView(model: model, store: store, course: course)
            }
        }
    }

    // MARK: - Term

    /// The term, beside the title rather than in a block of its own.
    ///
    /// A whole card to say "Fall 2026" spends the most valuable strip of the
    /// screen on something that changes twice a year. As a chip it sits on the
    /// same line as the heading, scrolls away with it, and comes back at the top.
    @ViewBuilder
    private var termChip: some View {
        if store.terms.count > 1 {
            HStack(spacing: 8) {
                Menu {
                    termMenuItems
                } label: {
                    HStack(spacing: 5) {
                        Text(store.selectedTerm?.title ?? store.terms[0].title)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(Neo.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Neo.accent.opacity(0.12), in: Capsule())
                }
                .accessibilityLabel(Text("Term"))

                if store.isSwitchingTerm {
                    ProgressView().controlSize(.small)
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private var termMenuItems: some View {
        Picker(
            "Term",
            selection: Binding(
                get: { store.selectedTerm ?? store.terms.first },
                set: { if let term = $0 { store.select(term: term) } }
            )
        ) {
            ForEach(store.terms) { term in
                Text(term.title).tag(Optional(term))
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch store.overview {
        case .idle, .loading:
            LeaPlaceholder(message: Text("Opening \(model.institution.conventions.courseworkDisplayName)…"))

        case .failed(let message):
            LeaFailureCard(message: message) { store.refresh() }

        case .loaded(let overview):
            if overview.courses.isEmpty {
                // Léa answers an out-of-session term with a page that simply
                // has no cards. That is an answer, not a failure.
                ContentUnavailableView(
                    "No Classes This Term",
                    systemImage: "books.vertical",
                    description: Text("Pick another term above, or check back once registration opens.")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                ForEach(overview.courses) { course in
                    LeaCourseCard(
                        model: model,
                        store: store,
                        course: course,
                        title: store.displayTitle(for: course),
                        // Nil means "push it"; a closure means there is a
                        // second column waiting for it.
                        onSelect: prefersSplitLayout ? { selected = $0 } : nil,
                        selection: selected,
                        // Held here rather than inside the card: a lazy stack
                        // rebuilds a card that scrolls far enough away, and a
                        // section would fold itself back up on the way past.
                        isExpanded: Binding(
                            get: { expanded.contains(course.id) },
                            set: { isOpen in
                                if isOpen { expanded.insert(course.id) }
                                else { expanded.remove(course.id) }
                            }
                        )
                    )
                }
            }
        }
    }
}

/// A card that acknowledges the tap without bouncing.
///
/// A small, quick scale is the whole effect: this is a list of links, not
/// something being thrown, and it is skipped entirely when the reader has asked
/// for less motion.
struct LeaPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Course card

/// One course, summarised exactly as far as the landing page already knows.
///
/// Everything here came free with the page that listed the courses, so the card
/// is complete without a second request — which is what lets the tab open in
/// one page load instead of seven.
struct LeaCourseCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: LeaStore
    let course: LeaCourse
    /// The course's proper name, which Léa's own card does not carry in full.
    let title: String
    /// Set when the destination opens in a column beside this one rather than
    /// on top of it. Nil on a phone, where a link that pushes is the right
    /// control and comes with the back gesture for free.
    var onSelect: ((LeaRoute) -> Void)?
    /// What that column is currently showing, so the card can say which of its
    /// rows the reader is looking at.
    var selection: LeaRoute?
    /// Folded away until asked for, so six courses fit on one screen.
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var personalization = Personalization.shared
    @State private var isEditingAppearance = false

    private var identity: CourseIdentity {
        store.identity(for: course)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Two separate targets on one banner: the name opens the course,
            // the arrow beside it opens the summary. Nesting the arrow inside
            // the link would have made it unreachable — the link swallows the
            // whole label — so they sit side by side and each is its own button.
            HStack(spacing: 0) {
                link(to: .course(course)) {
                    header
                }

                if !rows.isEmpty {
                    Button {
                        if reduceMotion {
                            isExpanded.toggle()
                        } else {
                            withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.18), in: Circle())
                            .padding(.trailing, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? Text("Hide summary") : Text("Show summary"))
                }
            }
            .background(identity.gradient)

            // Each row is its own way in. Reading "Your current grade 14.2/16"
            // and then having to tap the header, find the tile and tap again is
            // two steps to reach the thing already being looked at.
            if isExpanded {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 48) }
                    link(to: route(for: row.destination)) {
                        LeaSummaryRow(
                            icon: row.icon,
                            label: row.label,
                            value: row.value,
                            detail: row.detail,
                            valueIsProse: row.valueIsProse,
                            badge: row.badge,
                            // Tinted, not grey: everything in this card is a
                            // link, and a greyed control reads as one that is
                            // switched off.
                            tint: row.tint ?? identity.start
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            selection == route(for: row.destination)
                                ? identity.start.opacity(0.12)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Neo.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu {
            Button {
                isEditingAppearance = true
            } label: {
                Label("Change Icon", systemImage: "paintbrush")
            }
        }
        .sheet(isPresented: $isEditingAppearance) {
            CourseAppearanceEditor(code: course.code, title: title)
        }
    }

    /// A banner the course can be recognised by before a word of it is read.
    ///
    /// The symbol and the colour both come from the discipline in the course
    /// code, so Calculus looks like Calculus on every screen — and the code and
    /// the name are still printed, because the picture is the shortcut and not
    /// the information.
    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: identity.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(course.code)
                        .font(.caption.weight(.bold))
                        .monospaced()
                        .foregroundStyle(.white.opacity(0.92))

                    Text(identity.subject)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let teacher = course.teacher {
                    Text(teacher)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // No chevron. The disclosure arrow beside this is the only arrow
            // the card needs; a second one pointing a different way next to it
            // read as clutter rather than as an affordance.
            if course.unreadCount > 0 {
                LeaBadge(count: course.unreadCount)
            }
        }
        .padding(16)
        // The gradient moved out to the row that also holds the disclosure
        // arrow, so the two controls share one unbroken banner.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens this class"))
    }

    // MARK: - Rows

    /// One summary line, and where tapping it goes.
    private struct Row: Identifiable {
        enum Destination: Hashable {
            case documents
            case assignments
            case grades
            case announcement(LeaAnnouncementSummary)
            case course
        }

        let id: String
        let icon: String
        let label: String
        var value: String?
        var detail: String?
        var valueIsProse = false
        var badge: Int?
        /// Nil means "use the course's own colour".
        var tint: Color?
        let destination: Destination
    }

    /// The handful of rows worth repeating on the card.
    ///
    /// Not every section: a card that lists all eight is a table of contents,
    /// and the point of the stream is to be scannable.
    private var rows: [Row] {
        var rows: [Row] = []

        if let grades = course.section(.grades),
           let mark = grades.metrics.first(where: { $0.text != nil }) {
            rows.append(Row(
                id: "grades",
                icon: "chart.bar.fill",
                label: mark.label,
                value: mark.text,
                // Léa stacks the percentage under the mark. Kept on its own
                // line here for the same reason: run together they read as one
                // impossible number.
                detail: mark.detail,
                destination: .grades
            ))
        }

        if let documents = course.section(.documents) {
            let new = documents.metrics.first(where: \.isNew)?.count ?? 0
            let total = documents.metrics.first(where: { !$0.isNew && $0.count != nil })?.count
            rows.append(Row(
                id: "documents",
                icon: "doc.fill",
                label: documents.label,
                value: total.map { "\($0)" },
                badge: new > 0 ? new : nil,
                destination: .documents
            ))
        }

        // By Léa's own "new" marker, not by position. This row used to take
        // whatever happened to be printed second and put a red badge on it,
        // which is the same mistake this file avoids one level up — sections
        // are identified by their symbol precisely because their labels are
        // translated, and then their rows were being identified by index.
        // A school, term or language that prints them the other way round
        // swapped the two numbers with nothing to show for it.
        if let assignments = course.section(.assignments) {
            let new = assignments.metrics.first(where: \.isNew)?.count ?? 0
            let total = assignments.metrics.first(where: { !$0.isNew && $0.count != nil })?.count
            rows.append(Row(
                id: "assignments",
                icon: "tray.and.arrow.up.fill",
                label: assignments.label,
                value: total.map { "\($0)" },
                badge: new > 0 ? new : nil,
                destination: .assignments
            ))
        }

        if let absences = course.section(.absences), let hours = absences.trailingText {
            rows.append(Row(
                id: "absences",
                icon: "person.fill.questionmark",
                label: absences.label,
                value: hours,
                // Orange stays: this one is a warning rather than a link to
                // somewhere, and it goes to the course page for the detail.
                tint: .orange,
                destination: .course
            ))
        }

        if let announcement = course.section(.announcements)?.announcements.first {
            rows.append(Row(
                id: "announcement",
                icon: "megaphone.fill",
                label: announcement.date,
                value: announcement.title,
                valueIsProse: true,
                badge: announcement.isNew ? 1 : nil,
                destination: .announcement(announcement)
            ))
        }

        return rows
    }

    private func route(for destination: Row.Destination) -> LeaRoute {
        switch destination {
        case .documents: .documents(course)
        case .assignments: .assignments(course)
        case .grades: .grades(course)
        case .announcement(let summary): .announcement(course, summary)
        case .course: .course(course)
        }
    }

    /// The one control that is a push on a phone and a choice on an iPad.
    ///
    /// Written once because the two have to stay the same thing: a row that
    /// pushed on one and did nothing on the other is the exact bug that comes
    /// of writing the link twice.
    @ViewBuilder
    private func link<Label: View>(
        to route: LeaRoute,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if let onSelect {
            Button { onSelect(route) } label: { label() }
                .buttonStyle(LeaPressStyle())
                .accessibilityAddTraits(selection == route ? .isSelected : [])
        } else {
            NavigationLink(value: route) { label() }
                .buttonStyle(LeaPressStyle())
        }
    }
}

// MARK: - Shared pieces

struct LeaSummaryRow: View {
    let icon: String
    let label: String
    var value: String?
    /// The second line of a stacked value — a percentage under a mark.
    var detail: String?
    /// Long text belongs on the left where it can wrap; a count does not.
    var valueIsProse: Bool = false
    var badge: Int?
    var tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(valueIsProse ? 2 : 1)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            if let badge {
                LeaBadge(count: badge)
            }

            if let value {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(valueIsProse ? 2 : 1)
                        .multilineTextAlignment(.trailing)

                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// How far a download has got.
///
/// Determinate when the server said how big the file is, which for Léa it
/// almost always does — the list already prints "3.9 MB". Indeterminate only
/// when it did not, rather than a bar pinned at zero that looks stuck.
struct LeaDownloadBar: View {
    let progress: Double?
    var tint: Color = .accentColor

    var body: some View {
        Group {
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .tint(tint)
        .accessibilityLabel(Text("Downloading"))
        .accessibilityValue(
            progress.map { Text($0.formatted(.percent.precision(.fractionLength(0)))) } ?? Text("In progress")
        )
    }
}

/// The shape of content that has not arrived yet.
///
/// A shimmering outline of the real thing rather than a spinner in the middle
/// of an empty page: the reader can see what is coming and roughly how much of
/// it, and the layout does not jump when it lands. It shimmers only if the
/// reader has not asked for less motion.
struct LeaSkeleton: View {
    enum Shape {
        case hero
        case chart
        case rows(Int)
        case card
    }

    let shape: Shape

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        content
            .opacity(isPulsing ? 0.45 : 0.85)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Loading…"))
    }

    @ViewBuilder
    private var content: some View {
        switch shape {
        case .hero:
            block(height: 114, radius: 20)

        case .chart:
            VStack(alignment: .leading, spacing: 12) {
                block(height: 18, radius: 6).frame(width: 150)
                block(height: 170, radius: 12)
            }
            .padding(16)
            .neoCard()

        case .rows(let count):
            VStack(spacing: 0) {
                ForEach(0 ..< count, id: \.self) { index in
                    if index > 0 { Divider().padding(.leading, 16) }
                    HStack(spacing: 12) {
                        block(height: 34, radius: 9).frame(width: 34)
                        VStack(alignment: .leading, spacing: 6) {
                            block(height: 13, radius: 4)
                            block(height: 10, radius: 4).frame(maxWidth: 120)
                        }
                    }
                    .padding(16)
                }
            }
            .neoCard()

        case .card:
            block(height: 92, radius: 18)
        }
    }

    private func block(height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Neo.inset)
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

/// Léa's own "new since your last visit" counter, in the app's vocabulary.
struct LeaBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.red))
            .accessibilityLabel(Text("^[\(count) item](inflect: true) new or updated"))
    }
}

struct LeaPlaceholder: View {
    let message: Text

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            message
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct LeaFailureCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Button("Try Again", action: retry)
                .font(.subheadline.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Neo.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }
}

/// The header colours Léa uses for its own course cards.
///
/// Mirrored rather than replaced so a course keeps the colour the student
/// already associates with it from the website.
enum LeaPalette {
    private static let colors: [Color] = [
        Color(red: 0.16, green: 0.45, blue: 0.80),
        Color(red: 0.85, green: 0.44, blue: 0.16),
        Color(red: 0.28, green: 0.60, blue: 0.35),
        Color(red: 0.62, green: 0.30, blue: 0.68),
        Color(red: 0.83, green: 0.26, blue: 0.40),
        Color(red: 0.16, green: 0.60, blue: 0.64),
        Color(red: 0.45, green: 0.40, blue: 0.72)
    ]

    static func color(_ index: Int) -> Color {
        guard !colors.isEmpty else { return .accentColor }
        let position = max(0, index - 1) % colors.count
        return colors[position]
    }
}
