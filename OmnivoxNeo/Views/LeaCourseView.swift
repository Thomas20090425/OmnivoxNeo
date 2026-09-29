import SwiftUI

/// One course, with every section Léa publishes for it.
///
/// The sections are the ones the card advertised, in Léa's own order, so a
/// course whose teacher uses nothing but announcements shows exactly that
/// rather than five empty rows promising features the class does not use.
///
/// Laid out as tiles rather than a list. A list of six near-identical rows of
/// grey text is a thing you read; six tiles with their own symbol, colour and
/// count are things you aim at — which is the difference between navigating
/// this screen and parsing it.
struct LeaCourseView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: LeaStore
    let course: LeaCourse

    @Environment(\.dynamicTypeSize) private var typeSize
    // Observed so a change made in the icon editor reaches this screen.
    @ObservedObject private var personalization = Personalization.shared
    @State private var isEditingAppearance = false

    private var conventions: PortalConventions { model.institution.conventions }
    private var identity: CourseIdentity { store.identity(for: course) }

    /// Two across normally, one at the accessibility text sizes — at those
    /// sizes a two-column tile holds about three words before it turns into a
    /// vertical stack of syllables.
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 12)]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header
                tiles
                onlineClass
                absences
                forum
                events
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle(course.code)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $isEditingAppearance) {
            CourseAppearanceEditor(code: course.code, title: store.displayTitle(for: course))
        }
        .task {
            // Fetched here so the course can offer its own teacher's sites
            // without the student having to find the global list first.
            store.loadTeacherSites()
            // And the sections start loading now rather than on the tap, so
            // opening one usually finds it already there.
            store.prefetch(for: course)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                // The symbol is the way in to changing it. A course the app
                // guessed wrong about is one the student is already looking at.
                Button {
                    isEditingAppearance = true
                } label: {
                    Image(systemName: identity.symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "paintbrush.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(identity.start)
                                .padding(4)
                                .background(.white, in: Circle())
                                .offset(x: 4, y: 4)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Change Icon"))

                VStack(alignment: .leading, spacing: 5) {
                    Text(identity.subject)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))

                    Text(store.displayTitle(for: course))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if !course.subtitle.isEmpty {
                Text(course.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(identity.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - The sections, as tiles

    private var tiles: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            if let section = course.section(.documents) {
                NavigationLink {
                    LeaDocumentsView(store: store, course: course)
                } label: {
                    LeaTile(
                        symbol: "doc.text.fill",
                        title: section.label,
                        detail: total(in: .documents),
                        badge: newCount(in: .documents),
                        tint: identity.start
                    )
                }
                .buttonStyle(LeaPressStyle())
            }

            if let section = course.section(.assignments) {
                NavigationLink {
                    LeaAssignmentsView(model: model, store: store, course: course)
                } label: {
                    LeaTile(
                        symbol: "tray.and.arrow.up.fill",
                        title: section.label,
                        detail: total(in: .assignments),
                        badge: newCount(in: .assignments),
                        tint: identity.start
                    )
                }
                .buttonStyle(LeaPressStyle())
            }

            if let section = course.section(.grades) {
                NavigationLink {
                    LeaGradesView(store: store, course: course)
                } label: {
                    LeaTile(
                        symbol: "chart.line.uptrend.xyaxis",
                        title: section.label,
                        detail: gradeSummaryText,
                        badge: nil,
                        tint: identity.start
                    )
                }
                .buttonStyle(LeaPressStyle())
            }

            // Announcements take the fourth tile rather than the class forum,
            // which at Dawson is switched off in nearly every course. A tile is
            // for somewhere worth going.
            if let section = course.section(.announcements), !section.announcements.isEmpty {
                NavigationLink {
                    LeaAnnouncementsView(store: store, course: course)
                } label: {
                    LeaTile(
                        symbol: "megaphone.fill",
                        title: section.label,
                        detail: announcementDetail(section),
                        badge: section.announcements.filter(\.isNew).count,
                        tint: identity.start
                    )
                }
                .buttonStyle(LeaPressStyle())
            }

            // Recommended websites belong to the course, not to a separate
            // directory: a student looking for a reading is looking inside the
            // class it was set for.
            if let sites = store.sites(forCourseCode: course.code), sites.url != nil {
                NavigationLink {
                    LeaTeacherSitesView(store: store, teacher: sites)
                } label: {
                    LeaTile(
                        symbol: "link",
                        title: String(localized: "Websites"),
                        detail: sites.teacher,
                        badge: nil,
                        tint: identity.start
                    )
                }
                .buttonStyle(LeaPressStyle())
            }
        }
    }

    /// "Latest: Aug 18", so the tile says something more than its own name.
    private func announcementDetail(_ section: LeaSection) -> String? {
        section.announcements.first?.date
    }

    /// "19 documents", the way the card already counted them.
    private func total(in kind: LeaSection.Kind) -> String? {
        guard let section = course.section(kind) else { return nil }
        guard let metric = section.metrics.first(where: { !$0.isNew && $0.count != nil }) else {
            return section.metrics.first?.text
        }
        return "\(metric.label): \(metric.count ?? 0)"
    }

    private var gradeSummaryText: String? {
        guard let section = course.section(.grades) else { return nil }
        guard let metric = section.metrics.first(where: { $0.text != nil }) else { return nil }
        return [metric.text, metric.detail].compactMap { $0 }.joined(separator: "  ")
    }

    private func newCount(in kind: LeaSection.Kind) -> Int? {
        let count = course.section(kind)?.metrics.first(where: \.isNew)?.count ?? 0
        return count > 0 ? count : nil
    }

    // MARK: - Where the class happens

    /// Shown only when the class is *not* held in a room.
    ///
    /// Léa prints an "Online class: Classroom" row on every course, which for a
    /// class that meets in a classroom is a line of text confirming the
    /// ordinary. It earns its space only when the answer is surprising — and
    /// then it matters a great deal, because an online class is a live session
    /// with a joining link this app deliberately does not guess at.
    @ViewBuilder
    private var onlineClass: some View {
        if let section = course.section(.onlineClass),
           let mode = section.trailingText,
           !mode.isEmpty,
           !conventions.lea.inPersonClassKeywords.contains(where: { mode.localizedCaseInsensitiveContains($0) }) {
            LeaNoteCard(
                symbol: "video.fill",
                tint: .orange,
                title: section.label,
                value: mode,
                note: Loc.text("This class is not held in a classroom. Open the official Omnivox app or website to join it.")
            )
        }
    }

    /// The class forum, which Dawson turns off almost everywhere.
    ///
    /// Kept, because "your teacher has not enabled this" is an answer a student
    /// looking for it deserves — but as one quiet line rather than a quarter of
    /// the tile grid, which is space that belongs to somewhere you can go.
    @ViewBuilder
    private var forum: some View {
        if let section = course.section(.forum) {
            LeaNoteCard(
                symbol: "bubble.left.and.bubble.right.fill",
                tint: .secondary,
                title: section.label,
                value: section.trailingText,
                note: nil
            )
        }
    }

    // MARK: - Absences

    @ViewBuilder
    private var absences: some View {
        if let section = course.section(.absences), let hours = section.trailingText, !hours.isEmpty {
            LeaNoteCard(
                symbol: "person.fill.questionmark",
                tint: .orange,
                title: section.label,
                value: hours,
                note: Loc.text("Recorded by your teacher.")
            )
        }
    }

    // MARK: - Announcements

    static func announcementRow(_ item: LeaAnnouncementSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Unread is a dot *and* a bolder title, so it survives being
            // printed in greyscale or read by someone who cannot see the red.
            Circle()
                .fill(item.isNew ? Color.red : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(item.isNew ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.isNew ? .isSelected : [])
    }

    // MARK: - Events

    @ViewBuilder
    private var events: some View {
        if let section = course.section(.events), !section.events.isEmpty {
            LeaSectionHeading(section.label, symbol: "calendar", tint: identity.start) {
                VStack(spacing: 0) {
                    ForEach(Array(section.events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider().padding(.leading, 84) }
                        HStack(alignment: .top, spacing: 14) {
                            Text(event.date)
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(identity.start)
                                .frame(width: 56, alignment: .leading)

                            Text(event.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .accessibilityElement(children: .combine)
                    }
                }
                .neoCard()
            }
        }
    }
}

// MARK: - Pieces

/// One place to go, big enough to aim at without looking carefully.
///
/// Comfortably past the 44-point minimum in both directions, with the whole
/// tile tappable rather than just the words on it.
struct LeaTile: View {
    let symbol: String
    let title: String
    let detail: String?
    let badge: Int?
    let tint: Color
    var isEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isEnabled ? tint : Color.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        (isEnabled ? tint : Color.secondary).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                Spacer(minLength: 4)

                if let badge, badge > 0 {
                    LeaBadge(count: badge)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Neo.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(isEnabled ? 1 : 0.65)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isEnabled ? .isButton : [])
    }
}

/// A single fact with a sentence under it — attendance, delivery mode.
struct LeaNoteCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String?
    let note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    if let value {
                        Text(value)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tint == .secondary ? .primary : tint)
                    }
                }

                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
        .accessibilityElement(children: .combine)
    }
}

/// A titled group of content.
struct LeaSectionHeading<Content: View>: View {
    private let title: String
    private let symbol: String
    private let tint: Color
    private let content: Content

    init(_ title: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.headline)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }
            .padding(.leading, 2)

            content
        }
    }
}

// MARK: - Announcements

/// Every announcement in one course.
///
/// Its own page rather than a strip on the course screen: a teacher who posts
/// weekly builds up a list worth scrolling, and burying all but the newest of
/// them under a course header is how the others stop being read.
struct LeaAnnouncementsView: View {
    @ObservedObject var store: LeaStore
    let course: LeaCourse

    private var identity: CourseIdentity { store.identity(for: course) }

    private var announcements: [LeaAnnouncementSummary] {
        course.section(.announcements)?.announcements ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if announcements.isEmpty {
                    ContentUnavailableView(
                        "No Announcements",
                        systemImage: "megaphone",
                        description: Text("Your teacher has not posted anything for this course yet.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(announcements.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 16) }
                            if item.url != nil {
                                NavigationLink {
                                    LeaAnnouncementView(store: store, summary: item, tint: identity.start)
                                } label: {
                                    LeaCourseView.announcementRow(item)
                                }
                                .buttonStyle(LeaPressStyle())
                            } else {
                                LeaCourseView.announcementRow(item)
                                    .opacity(0.6)
                            }
                        }
                    }
                    .neoCard()
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle(Text("Announcements"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One announcement, as its own page.
struct LeaAnnouncementView: View {
    @ObservedObject var store: LeaStore
    let summary: LeaAnnouncementSummary
    var tint: Color = .accentColor

    private var state: LeaLoadable<LeaAnnouncement> {
        summary.url.flatMap { store.announcements[$0.absoluteString] } ?? .idle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch state {
                case .idle, .loading:
                    LeaSkeleton(shape: .rows(1))
                    LeaSkeleton(shape: .card)

                case .failed(let message):
                    LeaFailureCard(message: message) {
                        if let url = summary.url { store.loadAnnouncement(at: url) }
                    }

                case .loaded(let announcement):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(announcement.title)
                            .font(.title2.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)

                        if let course = announcement.courseLine {
                            Text(course)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let byline = announcement.byline {
                            Label(byline, systemImage: "person.crop.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // On its own opaque card, at body size, in the app's own
                    // text colour. Léa's HTML hard-codes black, which on a dark
                    // background is black on nearly black — the announcement
                    // was there the whole time and simply could not be read.
                    Text(LeaHTML.attributed(announcement.bodyHTML))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .tint(tint)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .neoCard()
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle(Text("Announcement"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if let url = summary.url { store.loadAnnouncement(at: url) }
        }
    }
}

/// Turns Léa's stored HTML into something `Text` can draw.
enum LeaHTML {
    @MainActor
    static func attributed(_ html: String) -> AttributedString {
        guard let data = html.data(using: .utf8) else { return AttributedString(html) }
        #if canImport(UIKit)
        guard let imported = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else {
            return AttributedString(html)
        }

        // The HTML importer stamps a colour and a point size on every run. Both
        // have to go, run by run — clearing them across the whole string leaves
        // the per-run values in place, which is how a teacher's announcement
        // came out black-on-black and pinned at 12pt while the rest of the app
        // followed the reader's chosen text size.
        let cleaned = NSMutableAttributedString(attributedString: imported)
        let whole = NSRange(location: 0, length: cleaned.length)
        cleaned.removeAttribute(.foregroundColor, range: whole)
        cleaned.removeAttribute(.backgroundColor, range: whole)

        // Emphasis is kept, because that is the teacher telling the student
        // which sentence mattered; only the typeface and the fixed size go.
        cleaned.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? UIFont else { return }
            let traits = font.fontDescriptor.symbolicTraits
            var replacement = UIFont.preferredFont(forTextStyle: .body)
            var wanted: UIFontDescriptor.SymbolicTraits = []
            if traits.contains(.traitBold) { wanted.insert(.traitBold) }
            if traits.contains(.traitItalic) { wanted.insert(.traitItalic) }
            if !wanted.isEmpty,
               let descriptor = replacement.fontDescriptor.withSymbolicTraits(wanted) {
                replacement = UIFont(descriptor: descriptor, size: 0)
            }
            cleaned.addAttribute(.font, value: replacement, range: range)
        }

        var result = AttributedString(cleaned)
        // Collapse the run of blank paragraphs Léa's editor leaves behind.
        while let range = result.range(of: "\n\n\n") {
            result.replaceSubrange(range, with: AttributedString("\n\n"))
        }
        return result
        #else
        return AttributedString(html)
        #endif
    }
}
