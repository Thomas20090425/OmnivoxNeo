import SwiftUI
import WebKit

/// Choosing who a message goes to.
///
/// MIO's own picker is three screens behind one button: a menu of ways to find
/// somebody, a browser of the student's own classes, and a search across the
/// college. All three are real, and all three are worth keeping — the college
/// decides who a student may write to, and an app that re-implemented that
/// would either hide people or offer ones whose messages bounce.
///
/// So the decisions stay on MIO's side and only the *surface* is replaced. Each
/// screen is read into a plain description of itself, drawn with the app's own
/// controls, and every tap handed straight back to the node it came from. A
/// search is a search field; a class is a row that opens; a chosen person is a
/// chip with a cross on it. What a student never sees is a 605-pixel-tall
/// fixed-height panel built for a mouse.
///
/// When the page is one this app has not been shown — a college with its own
/// build, or a screen added since — it shows MIO's own page instead of
/// pretending. That is also always reachable on purpose, from the menu.
struct MioRecipientPicker: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var session: MioComposeSession
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    /// Which of MIO's own headings the results are narrowed to. Nil is all of
    /// them; the values are MIO's words, never this app's.
    @State private var sectionFilter: String?
    @State private var showsOriginal = false
    @State private var isCommitting = false
    @State private var commitFailed = false
    @FocusState private var isSearchFocused: Bool

    private var page: MioPickerPage? { session.picker }

    var body: some View {
        content
            // Said over the top of the picker rather than instead of it: a
            // recipient who would not come off is a thing that did not work,
            // not a directory that failed to open.
            .overlay(alignment: .top) { notice }
            // Over the top of everything, and it takes the taps.
            //
            // Every action here is a page load at the college's end — three or
            // four seconds for a search, the same to add one person. A screen
            // that looks finished for four seconds gets pressed again, and a
            // second press on a list MIO is halfway through redrawing is how
            // the wrong name comes off it.
            .overlay { activity }
            .animation(.snappy(duration: 0.25), value: session.pickerNotice)
            .animation(.easeInOut(duration: 0.2), value: session.pickerActivity)
            .background(NeoBackground())
            .navigationTitle(Text(title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // Added somebody: said with a tap you can feel, because the row
            // itself does not move and the only other evidence is a chip
            // appearing at the top of a screen you are not looking at.
            .sensoryFeedback(trigger: page?.chosen.count ?? 0) { before, after in
                after > before ? .success : .impact(weight: .light)
            }
            // One back arrow, doing what a back arrow does. On a sub-screen it
            // returns to the menu of ways to search; on the menu it returns to
            // the message. It used to leave for the message from anywhere, with
            // a separate link inside the page for going up one level — two
            // controls for one idea, and the wrong one was where the thumb is.
            .navigationBarBackButtonHidden(true)
            // The edge swipe is the same door as the arrow, so it closes with
            // it: a gesture that abandons the selection is the gesture that
            // breaks the picker.
            .interactiveDismissDisabled(session.pickerFailure == nil)
            .toolbar {
                // Back only ever moves *inside* the picker — up from a search
                // or a class list to the menu. It is not a way out.
                //
                // It used to be one, and that was the bug behind every report
                // of a recipient that would not come off. MIO keeps the chosen
                // list on its own side and only hands it to the form when its
                // Save is pressed, so leaving by the back arrow threw the
                // change away: take your only recipient off, and the Done
                // button vanished with them, leaving nothing to press but a
                // Back that discarded the removal and put the name straight
                // back in the To field.
                if canGoUpAScreen {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .accessibilityLabel(Text("Back to the list of ways to search"))
                    }
                }
                // No Cancel here on purpose. This screen is one step of writing
                // a message, not a thing of its own to abandon — and the Cancel
                // that throws the whole message away belongs on the message.
                ToolbarItem(placement: .primaryAction) {
                    if isCommitting {
                        ProgressView()
                    } else {
                        // Always. An empty selection is a real answer — it is
                        // how somebody is taken off the list — and the version
                        // that only offered Done when *somebody* was chosen
                        // made that the one thing you could not finish.
                        Button {
                            finish()
                        } label: {
                            Label("Done", systemImage: "checkmark")
                        }
                        .fontWeight(.semibold)
                    }
                }
                // Internal builds only.
                //
                // Driving MIO's own page by hand leaves its server-side
                // selection in a state the app then disagrees with, and the
                // picker misbehaves afterwards. It stays for whoever is
                // debugging a college whose build this app has not been
                // shown — and the fallback that matters, the one for a page
                // this app cannot read at all, is automatic and unaffected:
                // `content` shows MIO's own page whenever the screen is not
                // one it recognises.
                if AppRelease.channel == .internalBuild {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            showsOriginal.toggle()
                        } label: {
                            Label(
                                showsOriginal ? "Use the Simple View" : "Show the Original Page",
                                systemImage: showsOriginal ? "sparkles" : "safari"
                            )
                        }
                    }
                }
            }
            .task {
                if session.picker == nil { await session.refreshPicker(settling: true) }
                searchText = session.picker?.searchText ?? ""
            }
            // Leaving by the back arrow is a real way out, so the window is
            // closed and the form re-read here as well as after Done. Without
            // it the picker's window stayed open behind the screen, and the
            // next attempt to choose a recipient did nothing at all.
            .onDisappear {
                guard session.pickerWebView != nil else { return }
                Task { await session.finishPickingRecipients() }
            }
            // Coming back from MIO's own page, anything done over there has
            // to be read before this one is drawn again — otherwise the two
            // disagree about who is on the list, and the one you are looking
            // at is the wrong one.
            .onChange(of: showsOriginal) { _, isOriginal in
                guard !isOriginal else { return }
                Task { await session.refreshPicker(settling: true) }
            }
    }

    private var title: String {
        page?.title.nilIfBlank ?? Loc.text("Add Recipients")
    }

    /// Whether there is somewhere above this screen inside the picker.
    private var canGoUpAScreen: Bool {
        guard let page else { return false }
        return page.mode != .chooser && page.canGoBack
    }

    /// Up one screen inside the picker. Never out of it — leaving is `finish()`,
    /// because leaving without saving is what loses the change.
    private func goBack() {
        guard canGoUpAScreen else { return finish() }
        Task { await session.pickerGoBack() }
    }

    // MARK: - What is on screen

    /// What the college is doing, while it does it — and nothing else gets
    /// pressed until it is finished.
    @ViewBuilder
    private var activity: some View {
        if let what = session.pickerActivity {
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.12))
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)

                    Text(what)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
            }
            // The point of it: taps land here and go nowhere.
            .contentShape(Rectangle())
            .onTapGesture {}
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(what))
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let message = session.pickerNotice {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.orange)

                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    session.pickerNotice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = session.pickerFailure {
            ScrollView {
                LeaFailureCard(message: failure) {
                    Task { await session.beginPickingRecipients() }
                }
                .padding(20)
            }
        } else if let webView = session.pickerWebView, showsOriginal || page?.isNative == false {
            original(webView)
        } else if let page {
            native(page)
        } else {
            VStack(spacing: 14) {
                ProgressView()
                Text("Opening the directory…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func original(_ webView: WKWebView) -> some View {
        VStack(spacing: 0) {
            if page?.isNative == false {
                // Said plainly rather than shown as a silent fallback: a page
                // that suddenly looks like 2009 with no explanation reads as a
                // bug, and this one is a deliberate handover.
                Label(
                    "This part of the directory is shown as MIO's own page.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            MioPickerWebView(webView: webView)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private func native(_ page: MioPickerPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                chosen(page)

                if !page.instructions.isEmpty {
                    Text(page.instructions)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                switch page.mode {
                case .chooser: chooser(page)
                case .search: search(page)
                case .groups: groups(page)
                case .unknown: EmptyView()
                }

                if commitFailed {
                    Label(
                        "Saving this selection needs MIO's own page. It is open below.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                }

                if !page.warning.isEmpty {
                    Text(page.warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 720)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if page.isBusy {
                ProgressView()
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: - Who has been chosen

    @ViewBuilder
    private func chosen(_ page: MioPickerPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sending to")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !page.chosen.isEmpty {
                    Text("\(page.chosen.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Neo.accent)
                }
            }

            if page.chosen.isEmpty {
                Text("Nobody yet. Pick somebody below.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(page.chosen) { person in
                        Button {
                            Task { await session.pickerRemove(person) }
                        } label: {
                            HStack(spacing: 5) {
                                Text(person.name)
                                    .font(.caption.weight(.medium))
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Neo.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(Neo.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(person.name))
                        .accessibilityHint(Text("Removes this recipient"))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
    }

    // MARK: - The menu

    private func chooser(_ page: MioPickerPage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groupedOptions(page), id: \.0) { heading, options in
                VStack(alignment: .leading, spacing: 0) {
                    if !heading.isEmpty {
                        Text(heading)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 6)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            if index > 0 { Divider().padding(.leading, 52) }
                            Button {
                                Task { await session.pickerTap(option.id, named: option.title) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: symbol(for: option))
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Neo.accent)
                                        .frame(width: 30, height: 30)
                                        .background(
                                            Neo.accent.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        )

                                    Text(option.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Spacer(minLength: 8)

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(LeaPressStyle())
                        }
                    }
                    .neoCard()
                }
            }
        }
    }

    /// Groups the menu's links under the headings MIO printed above them,
    /// keeping both in the order they appeared.
    private func groupedOptions(_ page: MioPickerPage) -> [(String, [MioPickerPage.Option])] {
        var order: [String] = []
        var buckets: [String: [MioPickerPage.Option]] = [:]
        for option in page.options {
            if buckets[option.group] == nil {
                order.append(option.group)
                buckets[option.group] = []
            }
            buckets[option.group]?.append(option)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// A picture for a menu item, chosen from what it is plainly about.
    ///
    /// Matched on MIO's own words, which are translated — so a miss costs a
    /// generic symbol and nothing else. Nothing here decides what the row
    /// *does*; that is still MIO's link.
    private func symbol(for option: MioPickerPage.Option) -> String {
        let text = (option.title + " " + option.group).lowercased()
        if text.contains("recherche") || text.contains("search") || text.contains("nom") {
            return "magnifyingglass"
        }
        if text.contains("favor") || text.contains("favour") {
            return "star"
        }
        if text.contains("class") || text.contains("cours") || text.contains("group") {
            return "person.3"
        }
        return "person.crop.circle"
    }

    // MARK: - Searching the college

    private func search(_ page: MioPickerPage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if !page.searchLabel.isEmpty {
                    Text(page.searchLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)

                    TextField(text: $searchText) {
                        Text("Name or keyword")
                    }
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .onSubmit { runSearch() }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Clear search"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Neo.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))

                Button("Search") { runSearch() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !page.results.isEmpty {
                results(page)
                if !page.overflowNote.isEmpty {
                    Text(page.overflowNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            } else if page.hasSearched || !page.emptyNote.isEmpty {
                ContentUnavailableView {
                    Label("Nobody Found", systemImage: "person.slash")
                } description: {
                    Text(page.emptyNote.nilIfBlank ?? Loc.text("Try a different name or keyword."))
                }
                .padding(.top, 20)
            }
        }
    }

    private func runSearch() {
        isSearchFocused = false
        // A filter from the last search has nothing to say about this one.
        sectionFilter = nil
        Task { await session.pickerSearch(searchText) }
    }

    // MARK: - The student's own classes

    private func groups(_ page: MioPickerPage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !page.filters.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(page.filters.enumerated()), id: \.element.id) { index, filter in
                        if index > 0 { Divider().padding(.leading, 16) }
                        HStack {
                            Text(filter.label)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Menu {
                                ForEach(filter.choices) { choice in
                                    Button {
                                        Task { await session.pickerFilter(filter.id, to: choice.id) }
                                    } label: {
                                        if choice.id == filter.selection {
                                            Label(choice.title, systemImage: "checkmark")
                                        } else {
                                            Text(choice.title)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(
                                        filter.choices.first { $0.id == filter.selection }?.title
                                            ?? filter.selection
                                    )
                                    .font(.subheadline.weight(.medium))
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2.weight(.bold))
                                }
                                .foregroundStyle(Neo.accent)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                }
                .neoCard()
            }

            VStack(spacing: 0) {
                ForEach(Array(page.groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().padding(.leading, 16) }
                    classRow(group)
                }
            }
            .neoCard()
        }
    }

    @ViewBuilder
    private func classRow(_ group: MioPickerPage.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard let expandID = group.expandID else { return }
                Task { await session.pickerTap(expandID) }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if !group.subtitle.isEmpty {
                            Text(group.subtitle)
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    if group.expandID != nil {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(group.isExpanded ? 180 : 0))
                    }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(LeaPressStyle())
            .disabled(group.expandID == nil)
            .accessibilityHint(group.isExpanded ? Text("Hides this class") : Text("Shows this class"))

            if group.isExpanded {
                if let addAllID = group.addAllID {
                    Button {
                        Task { await session.pickerTap(addAllID) }
                    } label: {
                        Label(
                            group.addAllTitle.nilIfBlank ?? Loc.text("Add everyone in this class"),
                            systemImage: "person.3.fill"
                        )
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Neo.accent)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LeaPressStyle())
                }

                if group.members.isEmpty {
                    Text(group.emptyNote.nilIfBlank ?? Loc.text("Nobody is listed for this class."))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                } else {
                    ForEach(group.members) { person in
                        personRow(person, indented: true)
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: - Results

    /// A search for "Thomas" comes back as fifty people: seven employees, four
    /// teachers and thirty-nine students, in one undifferentiated column. MIO
    /// files them under headings and this keeps those headings — its own words,
    /// so they are right in French too — and offers them as a filter, because
    /// a student looking for their teacher should not have to scroll past
    /// thirty-nine classmates to find them.
    @ViewBuilder
    private func results(_ page: MioPickerPage) -> some View {
        let exact = page.results.filter { Self.isExactMatch($0.name, for: searchText) }
        let rest = page.results.filter { !Self.isExactMatch($0.name, for: searchText) }
        let sections = orderedSections(rest)

        if sections.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    sectionChip(nil, count: page.results.count)
                    ForEach(sections, id: \.self) { section in
                        sectionChip(
                            section,
                            count: rest.filter { $0.section == section }.count
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }

        let shown = sections.filter { sectionFilter == nil || sectionFilter == $0 }
        VStack(alignment: .leading, spacing: 14) {
            // Searching "Thomas Ma" in MIO returns every Thomas at the college
            // and buries the one person whose name that is somewhere around
            // the thirtieth row. When the words typed *are* somebody's name,
            // that person goes first and is said to be why.
            if !exact.isEmpty, sectionFilter == nil {
                VStack(alignment: .leading, spacing: 0) {
                    Label("Exact match", systemImage: "target")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Neo.accent)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 6)
                    people(exact)
                }
            }

            ForEach(shown, id: \.self) { section in
                VStack(alignment: .leading, spacing: 0) {
                    if !section.isEmpty, shown.count > 1 || sectionFilter == nil {
                        Text(section)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 6)
                    }
                    people(rest.filter { $0.section == section })
                }
            }
        }
    }

    /// Whether these words *are* this person's name, rather than merely
    /// appearing in it.
    ///
    /// Compared as a set of words, because MIO writes "Ma, Thomas" and people
    /// type "Thomas Ma" — and with accents and punctuation set aside, so
    /// "Beliveau" finds Béliveau. One word is never an exact match: typing
    /// "Thomas" does not mean any particular Thomas.
    static func isExactMatch(_ name: String, for query: String) -> Bool {
        let wanted = words(of: query)
        guard wanted.count > 1 else { return false }
        return words(of: name) == wanted
    }

    private static func words(of text: String) -> Set<String> {
        Set(
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    /// The sections MIO actually returned, in the order it returned them.
    private func orderedSections(_ people: [MioPickerPage.Person]) -> [String] {
        var order: [String] = []
        for person in people where !order.contains(person.section) {
            order.append(person.section)
        }
        return order
    }

    private func sectionChip(_ section: String?, count: Int) -> some View {
        let isOn = sectionFilter == section
        return Button {
            sectionFilter = isOn && section != nil ? nil : section
        } label: {
            HStack(spacing: 5) {
                if let section, !section.isEmpty {
                    Text(section)
                } else {
                    Text("Everyone")
                }
                Text("\(count)")
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isOn ? Neo.accent.opacity(0.16) : Color.primary.opacity(0.06),
                in: Capsule()
            )
            .foregroundStyle(isOn ? Neo.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - People

    private func people(_ list: [MioPickerPage.Person]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, person in
                if index > 0 { Divider().padding(.leading, 68) }
                personRow(person, indented: false)
            }
        }
        .neoCard()
    }

    /// Whether this person is already on the list.
    ///
    /// By name, because that is all the two lists have in common: the panel of
    /// people already chosen is redrawn by MIO on its own side and its handles
    /// are not the ones the search results carry.
    private func isChosen(_ person: MioPickerPage.Person) -> Bool {
        guard let page else { return false }
        return page.chosen.contains { $0.name == person.name }
    }

    private func personRow(_ person: MioPickerPage.Person, indented: Bool) -> some View {
        let added = isChosen(person)
        return Button {
            // Pressing an added person takes them off again, which is what
            // pressing a tick everywhere else in the system does. It used to be
            // disabled, so the only way back was a chip that did not work
            // either — and a recipient you could add but not remove.
            Task { await session.pickerTap(person.id, named: person.name) }
        } label: {
            HStack(spacing: 12) {
                MioMonogram(name: person.name, correspondent: person.correspondent)
                    .scaleEffect(0.8)
                    .frame(width: 36, height: 36)
                    .opacity(added ? 0.55 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name)
                        .font(.subheadline)
                        .foregroundStyle(added ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    if !person.detail.isEmpty {
                        Text(person.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.body)
                    .foregroundStyle(added ? Color.green : Neo.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, indented ? 24 : 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(LeaPressStyle())
        .accessibilityLabel(Text(person.name))
        .accessibilityValue(added ? Text("Added") : Text(""))
        .accessibilityHint(added ? Text("Removes this person") : Text("Adds this person"))
    }

    // MARK: - Finishing

    private func finish() {
        isCommitting = true
        Task {
            let saved = await session.commitPicker()
            isCommitting = false
            if saved {
                dismiss()
            } else {
                // MIO's own save is the only thing that hands the names back,
                // so if this build's is not one the app recognises, the page
                // that has it is put on screen rather than the student being
                // told "Done" and quietly losing the selection.
                commitFailed = true
                showsOriginal = true
            }
        }
    }
}

/// The picker's own window, on screen for the screens this app does not draw.
struct MioPickerWebView: PlatformViewRepresentable {
    let webView: WKWebView

    #if canImport(UIKit)
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #endif
}
