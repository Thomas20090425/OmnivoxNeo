import SwiftUI

/// One message, as its own page.
///
/// A page rather than a sheet, for the same reason documents are: a message
/// with a teacher's instructions in it is a whole screen's worth of reading,
/// and a sheet can be swiped shut by accident halfway down it.
///
/// Opening this is also what tells OmniVox the message has been read. MIO does
/// that server-side when it serves the page, so the read state goes back
/// exactly as it would have if the student had opened it on the web — the list
/// on the portal, the counter in the menu and the badge on the tab all agree
/// afterwards without anything extra being sent.
struct MioMessageView: View {
    @ObservedObject var store: MioStore
    let message: MioMessage
    let onCompose: (MioDraft.Intent) -> Void
    /// What to do once this message no longer exists. On a phone that is
    /// nothing — the page pops itself — but where the message is a column
    /// beside the list, the column has to be told.
    var onDeleted: (() -> Void)?

    @State private var openFile: LeaOpenedFile?
    @State private var downloading: String?
    @State private var downloadError: String?
    @State private var isConfirmingDelete = false

    @Environment(\.dismiss) private var dismiss

    private var state: MioLoadable<MioMessageDetail> {
        store.message(for: message.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                switch state {
                case .idle, .loading:
                    LeaSkeleton(shape: .rows(2))
                    LeaSkeleton(shape: .card)

                case .failed(let text):
                    LeaFailureCard(message: text) { store.loadMessage(message) }

                case .loaded(let detail):
                    if !detail.recipients.isEmpty {
                        recipients(detail.recipients)
                    }

                    if let receipt = detail.readReceipt ?? message.readReceipt, message.isSent {
                        readReceipt(receipt)
                    }

                    body(detail)

                    if !detail.attachments.isEmpty {
                        attachments(detail.attachments)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 30)
        }
        .scrollContentBackground(.hidden)
        .background(NeoBackground())
        .navigationTitle(Text("Message"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.toggleFlag(message)
                } label: {
                    Image(systemName: message.isFlagged ? "flag.fill" : "flag")
                }
                .accessibilityLabel(message.isFlagged ? Text("Remove flag") : Text("Flag"))

                Menu {
                    Button {
                        onCompose(.reply(to: message.messageID))
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    Button {
                        onCompose(.replyAll(to: message.messageID))
                    } label: {
                        Label("Reply to All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    Button {
                        onCompose(.forward(of: message.messageID))
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    Divider()
                    Button {
                        store.toggleFollowUp(message)
                    } label: {
                        Label(
                            message.needsSecondRead ? "Remove Read-Again Mark" : "Mark to Read Again",
                            systemImage: message.needsSecondRead ? "bookmark.slash" : "bookmark"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("More"))

                // Its own button rather than a line in the menu. Deleting mail
                // is one of the three things anybody does on this screen, and
                // burying it behind an ellipsis is how an app ends up with a
                // reply button and no way to throw anything away.
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(store.deleting.contains(message.id))
                .accessibilityLabel(Text("Delete"))
            }
        }
        .task { store.loadMessage(message) }
        .navigationDestination(item: $openFile) { file in
            LeaFileReaderView(file: file)
        }
        .confirmationDialog(
            Text("Delete This Message?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(
                store.deletingIsPermanent ? "Delete Permanently" : "Delete",
                role: .destructive
            ) {
                store.delete(message)
                // Straight back to the list. The message is on its way out and
                // there is nothing left here to read — and if OmniVox turns it
                // down, the row comes back and says so where the student can
                // see it.
                if let onDeleted {
                    onDeleted()
                } else {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.deletingIsPermanent
                 ? "This message will be gone for good."
                 : "It moves to your deleted items in OmniVox.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(message.subject.isEmpty ? Loc.text("(No subject)") : message.subject)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                MioMonogram(name: message.name, correspondent: message.correspondent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.name)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        if let role = message.correspondentLabel {
                            Text(role)
                        }
                        Text(state.value?.dateText ?? message.dateText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func recipients(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("To", systemImage: "person.2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(names.joined(separator: ", "))
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
        .accessibilityElement(children: .combine)
    }

    /// The thing ordinary mail cannot tell you.
    private func readReceipt(_ receipt: MioReadReceipt) -> some View {
        HStack(spacing: 12) {
            Image(systemName: receipt.isComplete ? "eye.fill" : "eye")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(receipt.isComplete ? Color.green : Color.orange)
                .frame(width: 32, height: 32)
                .background(
                    (receipt.isComplete ? Color.green : Color.orange).opacity(0.14),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(receipt.isComplete ? "Everyone has read this" : "Not read by everyone yet")
                    .font(.subheadline.weight(.medium))
                Text(Loc.text("%@ of %@ recipients", "\(receipt.read)", "\(receipt.total)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard()
        .accessibilityElement(children: .combine)
    }

    private func body(_ detail: MioMessageDetail) -> some View {
        // Drawn as a document rather than as one `Text`. Two reasons, both of
        // them things students actually hit: staff paste charts and screenshots
        // into the middle of a MIO, which an attributed string has no way to
        // fetch and silently leaves out; and selecting inside a `Text` gives
        // you the whole message or nothing, so copying a room number meant
        // copying six paragraphs around it.
        MioBodyView(
            html: detail.bodyHTML,
            baseURL: detail.baseURL,
            websiteDataStore: store.websiteDataStore
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .neoCard()
    }

    private func attachments(_ files: [MioAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message.attachmentNote?.nilIfBlank.map { $0 == " " ? Loc.text("Attachments") : $0 }
                 ?? Loc.text("Attachments"))
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { Divider().padding(.leading, 52) }
                    attachmentRow(file)
                }
            }
            .neoCard()

            if let downloadError {
                Text(downloadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One attached file, opened in the app.
    ///
    /// Not a `Link`. The address is behind the signed-in session, so handing it
    /// to the browser means the student is either asked to sign in again or
    /// shown a sign-in page where their teacher's handout should be — and even
    /// when it works they have been dropped into Safari, which is not where
    /// they were. It is fetched with the same cookies the message was read
    /// with and opened in the same reader Léa's documents use.
    private func attachmentRow(_ file: MioAttachment) -> some View {
        Button {
            open(file)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "paperclip")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Neo.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        Neo.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let size = file.sizeText {
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if downloading == file.id {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(LeaPressStyle())
        .disabled(downloading != nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens this file"))
    }

    private func open(_ file: MioAttachment) {
        guard downloading == nil else { return }
        downloading = file.id
        downloadError = nil
        Task {
            defer { downloading = nil }
            do {
                let local = try await store.download(file, from: message)
                openFile = LeaOpenedFile(url: local, title: file.name)
            } catch {
                downloadError = (error as? MioService.Failure)?.message
                    ?? error.localizedDescription
            }
        }
    }
}
