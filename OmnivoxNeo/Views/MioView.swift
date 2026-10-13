import SwiftUI

/// Messages, laid out the way a mail app is laid out.
///
/// Deliberately the shape everyone already knows: a search field across the
/// top with the folder menu behind the button on its left, a list of
/// sender / subject / preview / date underneath it, and one button in the
/// corner for writing something new. A student who has used mail on a phone
/// has used this, which is the entire point — MIO's own interface is a
/// thirteen-column table built for a mouse, and it is where this app can be
/// most useful by simply not being that.
///
/// What it does *not* borrow is anything MIO does not have. There is no
/// presence dot, no chat tab, no second row of category tabs, and no avatar
/// menu, because nothing behind them exists here. Borrowing the parts without
/// the things is how an interface ends up full of controls that do nothing.
struct MioView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: MioStore

    @State private var isShowingFolders = false
    @State private var composing: MioDraft.Intent?
    /// Which message the other column is showing. Only used where there *is*
    /// another column.
    @State private var selected: MioMessage?
    @State private var columns: NavigationSplitViewVisibility = .doubleColumn
    /// Which message is waiting on an answer to "are you sure".
    @State private var pendingDelete: MioMessage?
    /// Pushed programmatically rather than by `NavigationLink`, because the
    /// row's tap now belongs to the swipe wrapper around it — a link inside
    /// would fire at the end of a swipe and open the message you were trying
    /// to flag.
    @State private var path = NavigationPath()
    @FocusState private var isSearching: Bool

    @Environment(\.prefersSplitLayout) private var prefersSplitLayout
    @Environment(\.sessionLimitation) private var limitation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if prefersSplitLayout {
                splitBody
            } else {
                stackBody
            }
        }
        // Keyed on the portal being ready rather than on this tab appearing —
        // see the same note in `LeaView`. A tap during a quiet restore used to
        // reach the sign-in form and come back as "your session expired".
        .task(id: model.portalIsIdle) {
            guard limitation == nil, model.portalIsIdle else { return }
            store.loadIfNeeded()
        }
        .animation(.snappy(duration: 0.25), value: store.notice)
        // A drawer that comes in from the side, which is where the button that
        // opens it is and where every mail app on every platform puts it. It
        // was a sheet from the bottom, which works and reads as something else
        // entirely — a bottom sheet is a thing you are being asked about, and
        // this is a place you are going.
        .overlay(alignment: .top) { noticeBanner }
        .overlay { folderDrawer }
        .sheet(item: $composing) { intent in
            MioComposeView(store: store, intent: intent)
        }
        .confirmationDialog(
            Text("Delete This Message?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { message in
            Button(
                store.deletingIsPermanent ? "Delete Permanently" : "Delete",
                role: .destructive
            ) {
                if selected?.id == message.id { selected = nil }
                store.delete(message)
            }
            Button("Cancel", role: .cancel) {}
        } message: { message in
            Text(deleteExplanation(for: message))
        }
    }

    /// What is about to happen, named, so "are you sure" is answerable.
    private func deleteExplanation(for message: MioMessage) -> String {
        let subject = message.subject.nilIfBlank ?? Loc.text("(No subject)")
        return store.deletingIsPermanent
            ? Loc.text("“%@” will be gone for good.", subject)
            : Loc.text("“%@” moves to your deleted items in OmniVox.", subject)
    }

    // MARK: - One column, or two

    /// A phone: the list is the screen, and a message is pushed on top of it.
    private var stackBody: some View {
        NavigationStack(path: $path) {
            listColumn
                #if os(iOS)
                .navigationBarHidden(true)
                #endif
                .navigationDestination(for: MioMessage.self) { message in
                    MioMessageView(store: store, message: message) { intent in
                        composing = intent
                    }
                }
        }
    }

    /// An iPad or a Mac: the list keeps its phone-sized column on the left and
    /// the message opens beside it.
    ///
    /// This is the shape every mail app on a big screen has, and the reason is
    /// not symmetry — it is that reading mail is a loop. Open, read, go back,
    /// open the next. On a phone that loop costs a push and a pop because there
    /// is nowhere else to put the message; on an iPad it was costing them for
    /// no reason at all, and the list you were working through disappeared
    /// every time you looked at something.
    private var splitBody: some View {
        NavigationSplitView(columnVisibility: $columns) {
            listColumn
                .navigationSplitViewColumnWidth(
                    min: SplitColumn.minWidth,
                    ideal: SplitColumn.idealWidth,
                    max: SplitColumn.maxWidth
                )
                #if os(iOS)
                .navigationBarHidden(true)
                #endif
        } detail: {
            NavigationStack {
                if let selected {
                    MioMessageView(
                        store: store,
                        message: selected,
                        onCompose: { composing = $0 },
                        onDeleted: { self.selected = nil }
                    )
                    // Rebuilt when the choice changes: the message view holds
                    // its own scroll position and its own web view, and reusing
                    // it leaves the next message opened halfway down.
                    .id(selected.id)
                } else {
                    noSelection
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // A folder is a different set of messages, so whatever was open is no
        // longer in the list beside it.
        .onChange(of: store.selectedFolderKey) { selected = nil }
    }

    private var listColumn: some View {
        ZStack(alignment: .bottomTrailing) {
            NeoBackground()

            content
                .safeAreaInset(edge: .top, spacing: 0) { searchBar }

            composeButton

            // A drag from the left edge opens the folders, which is how every
            // mail app on this platform works and the first thing anybody
            // tries. A narrow strip rather than the whole list, so it cannot
            // swallow a horizontal swipe meant for something else — and only
            // at the top level, where there is nothing behind to go back to.
            // The strip is laid out by the stack, and `contentShape` is applied
            // to the strip *only*.
            //
            // It was written as three chained frames with the content shape
            // last, which made the shape the size of the final frame — the
            // whole column. An invisible, full-screen, hit-testable rectangle
            // sat on top of the list and ate every tap and every scroll: the
            // messages, the compose button, all of it. Nothing about the
            // screen looked wrong, and none of it worked.
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 20)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { value in
                                guard value.translation.width > 40,
                                      abs(value.translation.height) < 60
                                else { return }
                                showFolders(true)
                            }
                    )

                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
        }
    }

    private var noSelection: some View {
        ZStack {
            NeoBackground()
            ContentUnavailableView(
                "No Message Open",
                systemImage: "envelope",
                description: Text("Pick something on the left to read it here.")
            )
        }
    }

    // MARK: - Saying what happened

    /// A line that appears, says what OmniVox did with the last flag or
    /// read-again mark, and goes away again.
    ///
    /// Over the top of everything, including a message that has been pushed
    /// open, because the control that started it is on both screens.
    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = store.notice {
            HStack(spacing: 10) {
                Image(systemName: notice.symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(notice.isFailure ? Color.orange : Color.green)

                Text(notice.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .allowsHitTesting(false)
        }
    }

    // MARK: - The folder drawer

    @ViewBuilder
    private var folderDrawer: some View {
        if isShowingFolders {
            ZStack(alignment: .leading) {
                // Tapping beside it closes it, which is the thing everyone
                // tries first.
                Rectangle()
                    .fill(.black.opacity(0.3))
                    .ignoresSafeArea()
                    .onTapGesture { showFolders(false) }
                    .accessibilityLabel(Text("Close folders"))
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)

                HStack(spacing: 0) {
                    MioFolderList(
                        title: model.institution.conventions.messagingDisplayName,
                        store: store,
                        onSelect: { folder in
                            store.select(folder)
                            selected = nil
                            showFolders(false)
                        }
                    )
                    .frame(maxWidth: 320)
                    .background(Neo.canvas)
                    .ignoresSafeArea(edges: .bottom)
                    .shadow(color: .black.opacity(0.2), radius: 16, x: 4)
                    // A flick back towards the edge puts it away, the same
                    // gesture that opened it in reverse.
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if value.translation.width < -40 { showFolders(false) }
                            }
                    )

                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .leading))
            }
        }
    }

    private func showFolders(_ open: Bool) {
        if reduceMotion {
            isShowingFolders = open
        } else {
            withAnimation(.snappy(duration: 0.28)) { isShowingFolders = open }
        }
    }

    // MARK: - The bar across the top

    /// One control doing three jobs, as in every mail app: it opens the
    /// folders, it searches, and it says where you are.
    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showFolders(true)
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Folders"))
                .accessibilityValue(Text(store.selectedFolder?.name ?? ""))

                TextField(
                    text: $store.query,
                    prompt: Text(searchPrompt)
                ) {
                    Text("Search messages")
                }
                .textFieldStyle(.plain)
                .focused($isSearching)
                .submitLabel(.search)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear search"))
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Neo.surface, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            // Tighter at the top where a floating tab bar already sits above
            // it: two stacked rounded bars with a gap between them read as a
            // mistake rather than as a hierarchy.
            .padding(.top, prefersSplitLayout ? 4 : 10)
            .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial)
    }

    /// "Search in Inbox" — the folder is named, because in a mail app the
    /// search field's scope is the one thing people get wrong about it.
    private var searchPrompt: String {
        guard let folder = store.selectedFolder else {
            return Loc.text("Search messages")
        }
        return Loc.text("Search in %@", folder.name)
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if limitation != nil, store.overview.value == nil {
            ContentUnavailableView(
                "Not Available Offline",
                systemImage: "wifi.slash",
                description: Text("Your messages are kept at the college, so they need a connection.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
        switch store.overview {
        case .idle, .loading:
            list(skeleton: true, messages: [])

        case .failed(let message):
            ScrollView {
                LeaFailureCard(message: message) { store.reload() }
                    .padding(20)
            }
            .scrollContentBackground(.hidden)

        case .loaded:
            switch store.currentList {
            case .idle, .loading:
                list(skeleton: true, messages: [])
            case .failed(let message):
                ScrollView {
                    LeaFailureCard(message: message) {
                        store.reloadMessages(in: store.selectedFolderKey)
                    }
                    .padding(20)
                }
                .scrollContentBackground(.hidden)
            case .loaded:
                list(skeleton: false, messages: store.visibleMessages)
            }
        }
        }
    }

    @ViewBuilder
    private func list(skeleton: Bool, messages: [MioMessage]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if skeleton {
                    LeaSkeleton(shape: .rows(6))
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                } else if messages.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index > 0 {
                            Divider().padding(.leading, 68)
                        }
                        MioSwipeRow(
                            // Both of these change something at the college,
                            // so neither is offered when it cannot be reached.
                            actionsEnabled: limitation == nil,
                            isFlagged: message.isFlagged,
                            onFlag: { store.toggleFlag(message) },
                            onDelete: { pendingDelete = message },
                            onTap: { openRow(message) }
                        ) {
                            rowLabel(message)
                        }
                        .contextMenu { rowMenu(message) }
                    }

                    if let total = store.currentList.value?.totalText, store.query.isEmpty {
                        Text(total)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 22)
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 96)
        }
        .scrollContentBackground(.hidden)
        .refreshable {
            guard limitation == nil else { return }
            store.refreshEverything()
        }
    }

    /// One row, which is a push on a phone and a choice on a bigger screen.
    ///
    /// The difference is real and not cosmetic: where the message opens beside
    /// the list, the row also has to say that it is the one being read, or the
    /// reader loses their place the moment they glance away.
    /// One row, drawn. Pressing it is the swipe wrapper's job.
    private func rowLabel(_ message: MioMessage) -> some View {
        MioRow(
            message: message,
            isUnread: store.isUnread(message),
            showsRecipientCount: store.selectedFolder?.kind == .sent,
            isSaving: store.pendingIndicators.contains(message.id)
        )
        // Where the message opens beside the list, the row also has to say it
        // is the one being read, or the reader loses their place the moment
        // they glance away.
        .background(
            prefersSplitLayout && selected?.id == message.id
                ? Neo.accent.opacity(0.12)
                : Color.clear
        )
    }

    /// What pressing a row does — a push on a phone, a choice on a bigger
    /// screen, and the editor for a draft, which is a message you are still
    /// writing rather than one to look at.
    private func openRow(_ message: MioMessage) {
        if let draft = draftIntent(for: message) {
            composing = draft
            return
        }
        if prefersSplitLayout {
            selected = message
        } else {
            path.append(message)
        }
    }

    /// What a long press on a row offers.
    ///
    /// Delete lives here rather than beside the flag in the row itself. A
    /// control that throws mail away must not sit a thumb's width from one that
    /// marks it — the flag is pressed by mistake all day and costs nothing, and
    /// this one is not and does.
    @ViewBuilder
    private func rowMenu(_ message: MioMessage) -> some View {
        if limitation != nil {
            Label("Not available offline", systemImage: "wifi.slash")
        } else {
        Button {
            store.toggleFlag(message)
        } label: {
            Label(
                message.isFlagged ? "Remove Flag" : "Flag",
                systemImage: message.isFlagged ? "flag.slash" : "flag"
            )
        }

        Button {
            store.toggleFollowUp(message)
        } label: {
            Label(
                message.needsSecondRead ? "Remove Read-Again Mark" : "Mark to Read Again",
                systemImage: message.needsSecondRead ? "bookmark.slash" : "bookmark"
            )
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = message
        } label: {
            Label(
                store.deletingIsPermanent ? "Delete Permanently" : "Delete",
                systemImage: "trash"
            )
        }
        }
    }

    /// How to open this row, when it is a draft MIO can reopen for editing.
    private func draftIntent(for message: MioMessage) -> MioDraft.Intent? {
        guard store.selectedFolder?.kind == .drafts else { return nil }
        return .draft(of: message.messageID)
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.query.isEmpty {
            ContentUnavailableView(
                "No Messages",
                systemImage: "tray",
                description: Text("Nothing has arrived in this folder.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            // Not "no results": this list is only as deep as the page MIO
            // sent, and saying otherwise would be claiming to have looked
            // through mail nobody has fetched.
            ContentUnavailableView {
                Label("Nothing Here Matches", systemImage: "magnifyingglass")
            } description: {
                Text("This searches the messages already loaded in this folder. Older ones may not be among them.")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
    }

    // MARK: - Writing

    private var composeButton: some View {
        Button {
            composing = .new
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                Text("Compose")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .background(Neo.accent, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(LeaPressStyle())
        .requiresTheCollege(limitation)
        .padding(.trailing, 20)
        .padding(.bottom, 22)
        .accessibilityLabel(Text("Compose"))
        .accessibilityHint(Text("Writes a new message"))
    }
}

// MARK: - Swiping a row

/// Drag a row to the left to uncover what you can do to it.
///
/// Hand-built because this list is not a `List`. It is a `LazyVStack` of rows
/// in a `ScrollView`, which is what lets it carry the monogram, the receipt
/// counts and the skeleton loading state — and `swipeActions` only exists on
/// `List`. Rebuilding the screen around one modifier would cost all of that.
///
/// The trick that keeps it simple: the buttons are drawn in a strip behind the
/// row that is exactly as wide as the row has been dragged. The row never
/// overlaps them, so it needs no opaque background of its own and the wallpaper
/// still shows through the list exactly as before.
private struct MioSwipeRow<Content: View>: View {
    let actionsEnabled: Bool
    let isFlagged: Bool
    let onFlag: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var isOpen = false
    /// Set the moment a horizontal drag begins, and cleared a beat after it
    /// ends.
    ///
    /// The row's press arrives on touch-up, which is *after* the drag has
    /// already moved the row — so this is what tells a swipe apart from a tap.
    /// Without it, swiping a row to flag it opened the message instead: the
    /// button underneath counted the whole gesture as a press because the
    /// finger never left its bounds.
    @State private var didDrag = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let actionWidth: CGFloat = 78
    private var openWidth: CGFloat { actionWidth * 2 }

    var body: some View {
        Button {
            if didDrag { return }
            if isOpen { settle(open: false); return }
            onTap()
        } label: {
            content()
        }
        .buttonStyle(LeaPressStyle())
            .offset(x: offset)
            .background(alignment: .trailing) { actions }
            // Simultaneous, not exclusive. An exclusive drag gesture on a row
            // inside a scroll view swallows the vertical scroll — this list has
            // been made untouchable by a gesture once already.
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard actionsEnabled else { return }
                        // Horizontal only. A vertical flick that wanders a few
                        // points sideways is somebody scrolling.
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5
                        else { return }
                        didDrag = true
                        let base = isOpen ? -openWidth : 0
                        offset = min(0, max(-openWidth - 24, base + value.translation.width))
                    }
                    .onEnded { value in
                        guard didDrag else { return }
                        let base = isOpen ? -openWidth : 0
                        settle(open: base + value.translation.width < -openWidth / 2)
                        // Long enough for the press this gesture is about to
                        // turn into to see it, and short enough that the next
                        // real tap does not.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            didDrag = false
                        }
                    }
            )
    }

    private var actions: some View {
        HStack(spacing: 0) {
            action(
                symbol: isFlagged ? "flag.slash.fill" : "flag.fill",
                label: isFlagged ? Text("Remove flag") : Text("Flag"),
                tint: .orange
            ) {
                settle(open: false)
                onFlag()
            }

            action(
                symbol: "trash.fill",
                label: Text("Delete"),
                tint: .red
            ) {
                settle(open: false)
                onDelete()
            }
        }
        // Exactly as wide as the row has moved, so the two never overlap.
        .frame(width: max(0, -offset))
        .clipped()
    }

    private func action(
        symbol: String,
        label: Text,
        tint: Color,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: actionWidth)
                .frame(maxHeight: .infinity)
                .background(tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func settle(open: Bool) {
        let change = {
            isOpen = open
            offset = open ? -openWidth : 0
        }
        if reduceMotion { change() } else { withAnimation(.snappy(duration: 0.25)) { change() } }
    }
}

// MARK: - One row

/// Sender, subject, a line of the message, and when it arrived.
///
/// Unread is said three ways over — a filled dot, a heavier weight, and a
/// word to VoiceOver — because it is the single most important fact on the
/// screen and the usual way of saying it is a shade of grey.
private struct MioRow: View {
    let message: MioMessage
    let isUnread: Bool
    let showsRecipientCount: Bool
    /// True while OmniVox is still being asked to agree.
    let isSaving: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MioMonogram(name: message.name, correspondent: message.correspondent)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.name.isEmpty ? Loc.text("Unknown sender") : message.name)
                        .font(.subheadline.weight(isUnread ? .bold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(message.dateText)
                        .font(.caption2.weight(isUnread ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isUnread ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }

                Text(message.subject.isEmpty ? Loc.text("(No subject)") : message.subject)
                    .font(.subheadline.weight(isUnread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    trailingMarks
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenLabel))
        .accessibilityAddTraits(isUnread ? .isSelected : [])
    }

    @ViewBuilder
    private var trailingMarks: some View {
        HStack(spacing: 8) {
            if message.hasAttachments {
                Image(systemName: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Sent mail carries the one thing ordinary mail cannot tell you.
            if showsRecipientCount, let receipt = message.readReceipt {
                Label {
                    Text(receipt.text)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: receipt.isComplete ? "eye.fill" : "eye")
                }
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(receipt.isComplete ? Color.green : Color.secondary)
            }

            if message.needsSecondRead {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // A mark, not a button.
            //
            // It used to be a control, sitting a thumb's width from the middle
            // of the row — which was already a hazard, and became a real one
            // once the row answered to a swipe: a swipe that starts on a
            // button is a press on that button, so trying to reveal the
            // actions by dragging across the flag silently flagged the
            // message instead. Flagging lives in the swipe and in the long
            // press now; this only says whether it is flagged.
            if isSaving {
                // Still being checked against OmniVox. The flag has already
                // moved; this says the answer is not in yet.
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 22)
            } else if message.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }

            if isUnread {
                Circle()
                    .fill(Neo.accent)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The row as one sentence, in the order somebody would say it.
    private var spokenLabel: String {
        var parts: [String] = []
        if isUnread { parts.append(Loc.text("Unread")) }
        parts.append(message.name)
        if let role = message.correspondentLabel { parts.append(role) }
        parts.append(message.subject)
        parts.append(message.dateText)
        if let note = message.attachmentNote?.nilIfBlank, note != " " { parts.append(note) }
        if message.isFlagged { parts.append(Loc.text("Flagged")) }
        if message.needsSecondRead { parts.append(Loc.text("Marked to read again")) }
        if showsRecipientCount, let receipt = message.readReceipt {
            parts.append(Loc.text("Read by %@ of %@", "\(receipt.read)", "\(receipt.total)"))
        }
        parts.append(message.preview)
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The circle with a letter in it, as every mail app draws a sender.
///
/// The colour is derived from the name rather than chosen, so the same person
/// is the same colour every time — which is what makes it worth anything at a
/// glance. The badge in the corner says whether they are a student, a teacher
/// or an administrator, which is a thing MIO knows and ordinary mail does not.
struct MioMonogram: View {
    let name: String
    let correspondent: MioMessage.Correspondent

    private static let palette: [Color] = [
        .blue, .indigo, .purple, .pink, .red, .orange, .brown, .green, .teal, .cyan
    ]

    private var tint: Color {
        guard !name.isEmpty else { return .gray }
        var hash: UInt64 = 5_381
        for byte in name.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Self.palette[Int(hash % UInt64(Self.palette.count))]
    }

    private var initials: String {
        let letters = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(tint.gradient)
                .frame(width: 44, height: 44)
                .overlay(
                    Text(initials)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                )

            if correspondent != .unknown {
                Image(systemName: correspondent.symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(3)
                    .background(Neo.surface, in: Circle())
                    .offset(x: 2, y: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The folder drawer

private struct MioFolderList: View {
    /// What the college calls its messaging, rather than the word "Folders" —
    /// this is the place you are in, and its name is the heading.
    let title: String
    @ObservedObject var store: MioStore
    let onSelect: (MioFolder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No close button. Tapping beside the drawer closes it, flicking
            // it closes it, and picking a folder closes it — a cross in the
            // corner is a fourth way to do a thing there are already three
            // ways to do.
            Text(title)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.folders.enumerated()), id: \.element.id) { index, folder in
                        if index > 0 {
                            // Faint, and inset past the symbols, so the list
                            // reads as one column rather than as six boxes.
                            Divider()
                                .padding(.leading, 62)
                                .opacity(0.5)
                        }
                        Button {
                            onSelect(folder)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: folder.symbol)
                                    .font(.body)
                                    .foregroundStyle(
                                        folder.key == store.selectedFolderKey
                                            ? Neo.accent
                                            : .secondary
                                    )
                                    .frame(width: 26)

                                Text(folder.name)
                                    .font(.body.weight(
                                        folder.key == store.selectedFolderKey ? .semibold : .regular
                                    ))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)

                                Spacer(minLength: 8)

                                if let count = folder.unreadCount, count > 0 {
                                    Text("\(count)")
                                        .font(.footnote.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Neo.accent)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .background(
                                folder.key == store.selectedFolderKey
                                    ? Neo.accent.opacity(0.12)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(LeaPressStyle())
                        .accessibilityAddTraits(
                            folder.key == store.selectedFolderKey ? .isSelected : []
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollContentBackground(.hidden)
        }
    }
}
