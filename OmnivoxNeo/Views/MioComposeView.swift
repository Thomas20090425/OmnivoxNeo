import SwiftUI
import WebKit

/// Writing a message.
///
/// Native, because a student writing to a teacher about a grade should not be
/// doing it inside a rich-text control from 2009 rendered in an iframe inside a
/// frameset. What gets typed here is put into MIO's own form and sent with
/// MIO's own button, so everything the page does on the way out — validating,
/// stripping images it will not carry, cancelling its auto-save — still
/// happens.
///
/// The one part that is not native is choosing who a **new** message goes to.
/// MIO's picker is a search across the whole college directory, opened in a
/// pop-up, and its address is not something this app has ever been shown. So
/// that one step is MIO's own screen, pushed like any other page. Replying,
/// replying to all and forwarding never reach it: MIO fills the recipients in
/// itself, which is why those are native from beginning to end.
struct MioComposeView: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var store: MioStore
    let intent: MioDraft.Intent

    @StateObject private var session: MioComposeSession
    @Environment(\.dismiss) private var dismiss
    @State private var isPickingRecipients = false
    @State private var isConfirmingClose = false
    @State private var isShowingAllRecipients = false
    @State private var isShowingPickerFailure = false
    @FocusState private var focus: Field?
    #if canImport(UIKit)
    @StateObject private var formatting = RichTextController()
    #endif

    private enum Field { case subject, body }

    init(store: MioStore, intent: MioDraft.Intent) {
        self.store = store
        self.intent = intent
        _session = StateObject(wrappedValue: store.composeSession())
    }

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle, .opening:
                    opening
                case .failed(let message):
                    ScrollView {
                        LeaFailureCard(message: message) {
                            Task { await session.start(intent) }
                        }
                        .padding(20)
                    }
                case .sent:
                    sent
                case .ready, .sending:
                    form
                }
            }
            .scrollContentBackground(.hidden)
            .background(NeoBackground())
            .navigationTitle(Text(title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Everything here is about a message still being written, so
                // none of it belongs on the screen that says it has gone.
                if session.phase != .sent {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            close()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                        .disabled(session.phase == .sending)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if session.phase == .sending {
                            ProgressView()
                        } else {
                            Button {
                                Task {
                                    await session.send()
                                    if session.phase == .sent {
                                        store.messageWasSent()
                                    }
                                }
                            } label: {
                                Label("Send", systemImage: "paperplane.fill")
                            }
                            .disabled(!canSend)
                        }
                    }
                }
            }
            .navigationDestination(isPresented: $isPickingRecipients) {
                MioRecipientPicker(session: session)
            }
            #if canImport(UIKit)
            // Above the keyboard, where a formatting bar belongs, and only
            // while the body is what is being typed into.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if focus == .body, session.phase == .ready {
                    MioFormattingBar(controller: formatting)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeOut(duration: 0.18), value: focus)
            #endif
        }
        .sheet(isPresented: Binding(
            get: { session.uploadWebView != nil },
            set: { if !$0 { Task { await session.finishAttaching() } } }
        )) {
            if let webView = session.uploadWebView {
                MioUploadSheet(webView: webView) {
                    Task { await session.finishAttaching() }
                }
            }
        }
        .task {
            if case .idle = session.phase {
                await session.start(intent)
            }
        }
        // MIO's own version of this question is a table of images asking
        // "Do you wish to save this Mio in your Draft folder?". Same question,
        // asked the way the rest of the system asks things.
        .confirmationDialog(
            Text("Save this as a draft?"),
            isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("Save Draft") {
                Task {
                    await session.saveDraft()
                    store.messageWasSent()
                    dismiss()
                }
            }
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Writing", role: .cancel) {}
        } message: {
            Text("Your draft is kept in the Drafts folder. Discarding deletes it.")
        }
        // A swipe down must not throw a message away.
        //
        // MIO keeps the recipients, the attachments and the auto-saved draft in
        // server-side state belonging to one open form, so leaving is a real
        // operation with a real question attached — save it or discard it. A
        // gesture that dismisses the sheet silently answers that question
        // without asking, and the answer it gives is the destructive one. The
        // way out is Cancel.
        .interactiveDismissDisabled()
        .alert(
            Text("The directory could not be opened."),
            isPresented: $isShowingPickerFailure
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again in a moment.")
        }
    }

    private var title: String {
        switch intent {
        case .new: Loc.text("New Message")
        case .reply, .replyAll: Loc.text("Reply")
        case .forward: Loc.text("Forward")
        case .draft: Loc.text("Draft")
        }
    }

    private var canSend: Bool {
        session.phase == .ready
            && !session.recipients.isEmpty
            && session.hasContent
    }

    // MARK: - Writing

    /// The body, with MIO's formatting available where the platform has it.
    @ViewBuilder
    private var bodyEditor: some View {
        #if canImport(UIKit)
        MioRichTextEditor(
            text: $session.bodyText,
            controller: formatting,
            placeholder: Loc.text("Write your message")
        )
        .frame(minHeight: 260)
        .focused($focus, equals: .body)
        #else
        EmptyView()
        #endif
    }

    /// What is attached, and the way to attach more.
    private var attachmentRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.attachments) { file in
                HStack(spacing: 10) {
                    Image(systemName: "paperclip")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Neo.accent)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.subheadline)
                            .lineLimit(2)
                        if !file.sizeText.isEmpty {
                            Text(file.sizeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    if file.removeID != nil {
                        Button {
                            Task { await session.removeAttachment(file) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove attachment"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }

            Button {
                Task { await session.beginAttaching() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "paperclip")
                        .font(.subheadline)
                    Text("Attach a file")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    if session.isAttaching { ProgressView().controlSize(.small) }
                }
                .foregroundStyle(Neo.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(LeaPressStyle())
            .disabled(session.isAttaching)
        }
    }

    // MARK: - States

    private var opening: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Opening…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Once it has gone, there is exactly one thing left to do.
    ///
    /// So everything else goes: no Cancel for a message that no longer exists
    /// to cancel, no Send for one already sent, no menu. A tick, three words
    /// and the button — anything more is offering choices that cannot be made.
    private var sent: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("Message sent")
                .font(.title2.weight(.semibold))

            Spacer(minLength: 0)

            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 420)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - The form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                recipientRow
                Divider()

                TextField(text: $session.draft.subject) {
                    Text("Subject")
                }
                .font(.body)
                .textFieldStyle(.plain)
                .focused($focus, equals: .subject)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                attachmentRow

                Divider()

                bodyEditor
                #if !canImport(UIKit)
                TextEditor(text: $session.draft.body)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .focused($focus, equals: .body)
                    .overlay(alignment: .topLeading) {
                        if session.draft.body.isEmpty {
                            Text("Write your message")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }

                #endif

                Divider()

                Toggle(isOn: $session.draft.hidesRecipients) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide the recipient list")
                            .font(.subheadline)
                        Text("The people who receive this will not see who else did.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: 760)
            .neoCard()
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    private var recipientRow: some View {
        Button {
            Task {
                await session.beginPickingRecipients()
                if session.pickerWebView != nil {
                    isPickingRecipients = true
                } else if session.pickerFailure != nil {
                    // Said out loud rather than swallowed: a control that has
                    // failed and stayed silent is indistinguishable from one
                    // that is broken for good.
                    isShowingPickerFailure = true
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("To")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)

                if session.recipients.isEmpty {
                    Text("Choose who this goes to")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    MioRecipientChips(
                        names: session.recipients,
                        isExpanded: $isShowingAllRecipients
                    )
                }

                Spacer(minLength: 6)

                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.body)
                    .foregroundStyle(Neo.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(LeaPressStyle())
        // Replies already know where they are going; changing that is still
        // allowed, but it is not the thing being asked for.
        .accessibilityLabel(Text("Recipients"))
        .accessibilityValue(
            session.recipients.isEmpty
                ? Text("None chosen")
                : Text(session.recipients.joined(separator: ", "))
        )
        .accessibilityHint(Text("Opens the directory"))
    }

    private func close() {
        if session.draft.hasContent {
            isConfirmingClose = true
        } else {
            dismiss()
        }
    }
}

// MARK: - Recipients, without the wall of names

/// A row of names that folds itself away once there are too many to read.
///
/// A MIO to a whole class is a hundred and twenty people, and a "To" field that
/// prints all of them buries the subject and the message under a paragraph of
/// names nobody is reading. Three and a count is enough to know what is going
/// on; the rest is one tap away, and the tap is its own control so it does not
/// fight the one that opens the directory.
struct MioRecipientChips: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    let names: [String]
    @Binding var isExpanded: Bool

    /// Enough to recognise who this is going to, few enough to stay one line.
    private let collapsedLimit = 3

    private var shown: [String] {
        isExpanded ? names : Array(names.prefix(collapsedLimit))
    }

    private var hidden: Int {
        max(0, names.count - collapsedLimit)
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Neo.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(Neo.accent)
            }

            if hidden > 0 {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 3) {
                        if isExpanded {
                            Text("Show fewer")
                        } else {
                            Text("+\(hidden)")
                                .monospacedDigit()
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isExpanded
                        ? Text("Show fewer recipients")
                        : Text("Show all \(names.count) recipients")
                )
            }
        }
    }
}

// MARK: - Chips that wrap

/// Lays its children out in rows, wrapping when it runs out of width.
///
/// `HStack` cannot do this and `LazyVGrid` wants fixed columns; recipient
/// names are every length from "Luke Reid" to "Georgeana Bobos-Kristof" and
/// need to flow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize(width: 0, height: 0)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                total.width = max(total.width, rowWidth)
                total.height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        total.width = max(total.width, rowWidth)
        total.height += rowHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - MIO's uploader

/// The upload page, shown as itself.
///
/// Uploading is the one thing here genuinely not worth re-implementing: the
/// page slices the file into ten-megabyte chunks, streams them to a handler
/// with a token of its own, and only then submits. What it does *not* need to
/// own is everything around it — so it arrives as a sheet with a real title and
/// a way out, closes itself when the upload finishes, and hands back a list of
/// files the app draws in its own hand.
struct MioUploadSheet: View {
    let webView: WKWebView
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            MioPickerWebView(webView: webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text("Attach a File"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            onFinish()
                        } label: {
                            Label("Done", systemImage: "checkmark")
                        }
                    }
                }
        }
    }
}
