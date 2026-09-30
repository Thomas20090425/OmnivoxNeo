import Charts
import SwiftUI

/// Grades, as the teacher entered them.
///
/// Marks are shown verbatim — "19.5/25", "78%", "1/1" — because a teacher's
/// own notation carries meaning the app cannot safely normalise. A dash in Léa
/// means the mark has not been released, which is a different thing from zero,
/// so unreleased rows are drawn as waiting rather than as failures.
///
/// The one number that *is* interpreted is the proportion, and only to draw a
/// bar beside the text that still says it in full. Nothing here is signalled by
/// colour alone: every bar has its number next to it, and every comparison with
/// the class is written out as well as drawn.
struct LeaGradesView: View {
    @ObservedObject var store: LeaStore
    let course: LeaCourse

    @ObservedObject private var personalization = Personalization.shared

    private var state: LeaLoadable<LeaGrades> {
        store.grades[course.id] ?? .idle
    }

    private var identity: CourseIdentity {
        store.identity(for: course)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                switch state {
                case .idle, .loading:
                    // Shaped like what is coming, so the page does not jump
                    // when it arrives.
                    LeaSkeleton(shape: .hero)
                    LeaSkeleton(shape: .chart)
                    LeaSkeleton(shape: .rows(3))

                case .failed(let message):
                    LeaFailureCard(message: message) { store.reloadGrades(for: course) }

                case .loaded(let grades):
                    if let summary = grades.summary {
                        hero(summary)
                        if !summary.yourProgression.isEmpty {
                            progression(summary)
                        }
                        if !summary.statistics.isEmpty {
                            statistics(summary.statistics)
                        }
                    }

                    if grades.categories.isEmpty {
                        ContentUnavailableView(
                            "No Grades Yet",
                            systemImage: "chart.bar.doc.horizontal",
                            description: Text("Nothing has been marked in this course yet.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(grades.categories) { category in
                            categoryCard(category)
                        }
                    }

                    if let teacher = grades.teacher {
                        Text(teacher)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
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
        .navigationTitle(Text("Grades"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { store.loadGrades(for: course) }
        .refreshable { store.reloadGrades(for: course) }
    }

    // MARK: - Hero

    /// The one number a student opens this screen for, at the size that says so.
    private func hero(_ summary: LeaGradeSummary) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 20) {
                GradeRing(fraction: summary.percentValue.map { $0 / 100 })

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your current grade")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))

                    Text(summary.currentGrade ?? summary.currentPercent ?? "—")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    if let percent = summary.currentPercent, summary.currentGrade != nil {
                        Text(percent)
                            .font(.headline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(identity.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Your current grade"))
        .accessibilityValue(
            Text([summary.currentGrade, summary.currentPercent].compactMap { $0 }.joined(separator: ", "))
        )
    }

    // MARK: - Progression

    /// Léa serves this graph as a server-rendered image, and every point on it
    /// as a tooltip. The tooltips are read and the chart drawn here instead.
    ///
    /// Not a stylistic preference: the image arrives at one fixed size in one
    /// fixed palette, ignores the reader's text size, turns to mud in dark
    /// mode, and cannot be read aloud. The numbers behind it can do all four.
    private func progression(_ summary: LeaGradeSummary) -> some View {
        let yours = summary.yourProgression
        let theirs = summary.classProgression
        let yourName = yours.first?.seriesName ?? String(localized: "You")
        let theirName = theirs.first?.seriesName ?? String(localized: "Class average")
        // Drawn from the left edge rather than from the first mark — see
        // `anchoredAtStart`.
        let yoursDrawn = anchoredAtStart(yours)
        let theirsDrawn = anchoredAtStart(theirs)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Average progression")
                    .font(.headline)

                Spacer(minLength: 8)

                // The scale lives on the chart as well as in Settings. A
                // preference about one graph is findable next to that graph and
                // very nearly invisible at the bottom of a page about wallpaper.
                Menu {
                    Picker(
                        "Chart Scale",
                        selection: Binding(
                            get: { personalization.gradeChartScale },
                            set: { personalization.setGradeChartScale($0) }
                        )
                    ) {
                        ForEach(GradeChartScale.allCases) { scale in
                            Text(scale.title).tag(scale)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(identity.start)
                        .frame(width: 32, height: 32)
                        .background(identity.start.opacity(0.12), in: Circle())
                }
                .accessibilityLabel(Text("Chart Scale"))
            }

            Chart {
                ForEach(theirsDrawn) { point in
                    LineMark(
                        x: .value(Text("Portion of the final grade"), point.cumulative),
                        y: .value(Text("Average"), point.value),
                        series: .value(Text("Line"), theirName)
                    )
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .interpolationMethod(.monotone)
                }

                ForEach(yoursDrawn) { point in
                    AreaMark(
                        x: .value(Text("Portion of the final grade"), point.cumulative),
                        y: .value(Text("Average"), point.value)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [identity.start.opacity(0.28), identity.start.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value(Text("Portion of the final grade"), point.cumulative),
                        y: .value(Text("Average"), point.value),
                        series: .value(Text("Line"), yourName)
                    )
                    .foregroundStyle(identity.start)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)

                    // Only on marks that exist. The lead-in's end is not an
                    // assessment and must not be dotted like one.
                    if point.date != nil {
                        PointMark(
                            x: .value(Text("Portion of the final grade"), point.cumulative),
                            y: .value(Text("Average"), point.value)
                        )
                        .foregroundStyle(identity.start)
                        .symbolSize(38)
                    }
                }
            }
            .chartYScale(domain: chartRange(yours + theirs))
            // Anchored at zero, because the axis measures how much of the
            // final grade has been handed back — and "none of it yet" is a
            // real, meaningful place for the line to start from. Letting it
            // begin at the first assessment made an early 1% look like the
            // beginning of the term's scale.
            .chartXScale(domain: 0 ... chartSpan(yours + theirs))
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            // Through the percent format style rather than by
                            // appending a sign: French puts a space before it.
                            Text((number / 100).formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            // Through the percent format style rather than by
                            // appending a sign: French puts a space before it.
                            Text((number / 100).formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                }
            }
            .frame(height: 190)
            // Without this the area fill under the line paints past the plot
            // and runs off down the page behind the cards below it.
            .chartPlotStyle { $0.clipped() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Average progression"))
            .accessibilityValue(Text(progressionSummary(yours: yours, theirs: theirs)))

            HStack(spacing: 16) {
                LegendSwatch(color: identity.start, label: yourName, isDashed: false)
                if !theirs.isEmpty {
                    LegendSwatch(color: .secondary, label: theirName, isDashed: true)
                }
            }

            // Only promises a comparison when there is one: plenty of teachers
            // keep the class statistics to themselves.
            Text(theirs.isEmpty
                 ? "Your average as more of the final grade is handed back."
                 : "Your average against the class, as more of the final grade is handed back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }

    /// The same series, extended back to the left edge of the chart.
    ///
    /// Léa's first plotted point sits at whatever portion of the final grade
    /// the first assessment was worth — 1%, usually — so the line and its fill
    /// began a visible gap away from the axis they are measured against. This
    /// carries the first mark flat back to zero so the plot meets the axis.
    ///
    /// It is a lead-in, not a reading: the added point is given no date, which
    /// is what keeps a dot off it, and it never changes the range, the summary
    /// or what is read aloud. The claim it makes — that your average was your
    /// first mark from the moment that mark existed — is true.
    private func anchoredAtStart(_ points: [LeaGradePoint]) -> [LeaGradePoint] {
        guard let first = points.first, first.cumulative > 0 else { return points }
        let origin = LeaGradePoint(
            series: first.series,
            seriesName: first.seriesName,
            // Negative, and distinct per series, so it cannot collide with a
            // real point's identity.
            step: -1 - first.series,
            value: first.value,
            cumulative: 0,
            date: nil
        )
        return [origin] + points
    }

    /// How far along the term the axis runs, from zero.
    ///
    /// Only as far as the marks go, with a little room at the end: stretching
    /// it to 100% would squeeze a term that is a quarter done into the left
    /// edge and claim, wrongly, that the rest is known to be coming.
    private func chartSpan(_ points: [LeaGradePoint]) -> Double {
        let furthest = points.map(\.cumulative).max() ?? 0
        return max(furthest * 1.06, 1)
    }

    /// A little headroom either side, so the line never touches the frame.
    ///
    /// Which of the two scales this is comes from the student's own setting:
    /// fitting the axis to the marks shows the shape of a term, and anchoring
    /// at zero is honest about how small most of that shape really is.
    private func chartRange(_ points: [LeaGradePoint]) -> ClosedRange<Double> {
        guard personalization.gradeChartScale == .dynamic else { return 0 ... 100 }
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0 ... 100 }
        let padding = max((high - low) * 0.18, 4)
        return max(0, low - padding) ... min(100, high + padding)
    }

    /// What the chart says, in words, for anyone not looking at it.
    private func progressionSummary(yours: [LeaGradePoint], theirs: [LeaGradePoint]) -> String {
        guard let latest = yours.last else { return "" }
        let mine = Loc.text("Your average is %@ percent after %@ percent of the final grade.",
                            Self.round(latest.value), Self.round(latest.cumulative))
        guard let other = theirs.last else { return mine }
        return mine + " " + Loc.text("The class average is %@ percent.", Self.round(other.value))
    }

    private static func round(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    // MARK: - Statistics

    private func statistics(_ values: [LeaGradeStatistic]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How the class did")
                .font(.headline)

            // A row each, rather than a grid: three short labels in columns
            // wrap into unreadable stacks at the larger text sizes.
            VStack(spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.element.id) { index, stat in
                    if index > 0 { Divider() }
                    HStack {
                        Text(stat.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(stat.value)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }

    // MARK: - Categories

    private func categoryCard(_ category: LeaGradeCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Nothing at all when the teacher grouped nothing. Not "No
            // section", not an empty heading — the marks simply start.
            if category.hasHeading {
            VStack(alignment: .leading, spacing: 6) {
                Text(category.name)
                    .font(.headline)

                HStack(spacing: 8) {
                    if let weight = category.weightText {
                        Label(weight, systemImage: "scalemass")
                            .labelStyle(.titleAndIcon)
                    }
                    if let average = category.averageText {
                        Label(average, systemImage: "chart.bar.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Stated at the top of the category, where Léa states it, and
                // in Léa's own words — because "the 4 lowest will be dropped"
                // changes what every mark below it means, and a student
                // planning the rest of their term is reading precisely this.
                if let rule = category.dropRule {
                    Label(rule, systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(identity.start)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(Array(category.items.enumerated()), id: \.element.id) { index, item in
                // A divider separates marks from each other and from the
                // heading. With no heading there is nothing above the first
                // one to separate it from.
                if category.hasHeading || index > 0 {
                    Divider().padding(.leading, 16)
                }
                gradeRow(item, in: category)
                    .id(index)
            }
        }
        .neoCard()
    }

    private func gradeRow(_ item: LeaGradeItem, in category: LeaGradeCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(item.isReleased ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if let mark = item.mark {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(mark)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            // Dimmed, never struck through: a dropped mark is
                            // still the student's mark, and a line through a
                            // number reads as "this number is wrong".
                            .foregroundStyle(item.isDiscarded ? .secondary : .primary)
                        if let percent = item.markPercent {
                            Text(percent)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    // Léa's dash, spelled out. "Not released" and "zero" look
                    // alike in a table and mean opposite things.
                    Text("Not marked yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let fraction = item.fraction {
                GradeBar(
                    fraction: fraction,
                    classFraction: item.classFraction,
                    // Grey rather than the course's colour, so a mark that does
                    // not count does not read as one that does at a glance.
                    tint: item.isDiscarded ? .secondary : identity.start
                )
            }

            HStack(spacing: 10) {
                countingPill(item, in: category)

                if let weight = item.weight {
                    Text(item.weightPoints.map { Loc.text("%@ of the grade (%@)", weight, $0) } ??
                         Loc.text("%@ of the grade", weight))
                }
                if let average = item.classAverage {
                    Text(Loc.text("Class %@", average))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            // Léa's own sentence, but only where the category header did not
            // already carry the rule — otherwise it is the same sentence
            // repeated under every dropped mark in the list.
            if item.isDiscarded, category.dropRule == nil, let note = item.discardNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let comment = item.comment {
                TeacherComment(comment: comment, tint: identity.start)
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    /// Whether this mark counts, said in a word, on both kinds of row.
    ///
    /// Only inside a category that drops marks — everywhere else every mark
    /// counts and a badge saying so on all of them is noise. Where marks *are*
    /// dropped it goes on the kept ones too, because the student's question is
    /// "which of these four still counts", and answering it only on the losers
    /// leaves the rest ambiguous. Word and symbol, not colour: dimming alone
    /// says nothing to a reader who cannot see it.
    @ViewBuilder
    private func countingPill(_ item: LeaGradeItem, in category: LeaGradeCategory) -> some View {
        if category.dropsMarks, item.isReleased {
            // Two `Text`s rather than one with a ternary inside it: a ternary
            // of string literals is a `String`, which sends `Text` to its
            // verbatim initializer and ships both words in English forever.
            Label {
                if item.isDiscarded {
                    Text("Dropped")
                } else {
                    Text("Counts")
                }
            } icon: {
                Image(systemName: item.isDiscarded ? "minus.circle.fill" : "checkmark.circle.fill")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(item.isDiscarded ? Color.secondary : identity.start)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (item.isDiscarded ? Color.secondary : identity.start).opacity(0.14),
                in: Capsule()
            )
        }
    }
}

// MARK: - Pieces

/// The current grade as a ring.
///
/// Drawn beside the number rather than instead of it: the ring is the glance,
/// the number is the answer.
private struct GradeRing: View {
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 8)

            Circle()
                .trim(from: 0, to: shown)
                .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))

            if let fraction {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(width: 74, height: 74)
        .accessibilityHidden(true)
        .onAppear {
            let target = min(max(fraction ?? 0, 0), 1)
            if reduceMotion {
                shown = target
            } else {
                withAnimation(.easeOut(duration: 0.7)) { shown = target }
            }
        }
    }
}

/// One assessment as a bar, with the class's mark notched on it.
private struct GradeBar: View {
    let fraction: Double
    let classFraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Neo.inset)

                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * fraction)

                // Where the rest of the class landed. A notch rather than a
                // second bar, because it is a reference line, not a total.
                if let classFraction {
                    Capsule()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 2)
                        .offset(x: max(0, min(proxy.size.width - 2, proxy.size.width * classFraction)))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct LegendSwatch: View {
    let color: Color
    let label: String
    let isDashed: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Solid against dashed, so the two lines stay apart for a reader
            // who cannot tell the colours apart.
            Capsule()
                .strokeBorder(color, style: StrokeStyle(lineWidth: 3, dash: isDashed ? [3, 2] : []))
                .frame(width: 18, height: 3)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the teacher wrote, quoted rather than paraphrased.
private struct TeacherComment: View {
    let comment: LeaGradeComment
    let tint: Color

    @State private var isExpanded = false

    private var isLong: Bool { comment.body.count > 220 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(comment.heading, systemImage: "text.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(comment.body)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(isExpanded || !isLong ? nil : 4)

            if isLong {
                Button(isExpanded ? "Show less" : "Read all") {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(tint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Neo.inset)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
    }
}
