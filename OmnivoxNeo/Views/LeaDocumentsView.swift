import SwiftUI

/// The documents and videos a teacher has distributed, in their own categories.
///
/// Two kinds of row live here and they behave differently on purpose. A file
/// belongs to the course and opens inside the app; a link belongs to the open
/// web and leaves it. Blurring the two would mean a student tapping "Slides"
/// and "Anatomy of Fascism" gets the same promise and a different outcome.
struct LeaDocumentsView: View {
    @ObservedObject var store: LeaStore
    let course: LeaCourse

    @State private var openFile: LeaOpenedFile?
    @State private var pendingLink: LeaDocument?
    @State private var downloading: String?
    @State private var downloadError: String?

    @Environment(\.openURL) private var openURL
    @ObservedObject private var personalization = Personalization.shared

    private var state: LeaLoadable<[LeaDocumentCategory]> {
        store.documents[course.id] ?? .idle
    }

    private var identity: CourseIdentity { store.identity(for: course) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                switch state {
                case .idle, .loading:
                    LeaSkeleton(shape: .rows(4))
                    LeaSkeleton(shape: .rows(2))

                case .failed(let message):
                    LeaFailureCard(message: message) { store.reloadDocuments(for: course) }

                case .loaded(let categories):
                    if categories.isEmpty {
                        ContentUnavailableView(
                            "No Documents",
                            systemImage: "doc",
                            description: Text("Your teacher has not distributed anything for this course yet.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(categories) { category in
                            section(category)
                        }
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
        .navigationTitle(Text("Documents"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { store.loadDocuments(for: course) }
        .refreshable { store.reloadDocuments(for: course) }
        // Pushed, not presented. A sheet gives up the top of the screen to a
        // grabber and can be swiped away by accident halfway through a page of
        // slides; a pushed page gets the whole screen and only leaves when the
        // reader means it to.
        .navigationDestination(item: $openFile) { file in
            LeaFileReaderView(file: file)
        }
        // An alert rather than a card at the foot of the page: this is the
        // answer to something the student just tapped, and it has to arrive
        // where they are looking.
        .alert(
            Text("Couldn’t open that"),
            isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })
        ) {
            Button("OK", role: .cancel) { downloadError = nil }
        } message: {
            if let downloadError { Text(downloadError) }
        }
        .confirmationDialog(
            Text(pendingLink?.title ?? ""),
            isPresented: Binding(
                get: { pendingLink != nil },
                set: { if !$0 { pendingLink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Open in Browser") {
                if let link = pendingLink, case .externalLink(let url) = link.destination {
                    store.markRead(link)
                    openURL(url)
                }
                pendingLink = nil
            }
            Button("Cancel", role: .cancel) { pendingLink = nil }
        } message: {
            if case .externalLink(let url) = pendingLink?.destination {
                Text("This is a link to another website. It will open in your browser.\n\n\(url.host() ?? url.absoluteString)")
            }
        }
    }

    private func section(_ category: LeaDocumentCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !category.name.isEmpty {
                Text(category.name)
                    .font(.headline)
                    .padding(.leading, 2)
            }

            VStack(spacing: 0) {
                ForEach(Array(category.documents.enumerated()), id: \.element.id) { index, document in
                    if index > 0 { Divider().padding(.leading, 66) }
                    Button {
                        open(document)
                    } label: {
                        LeaDocumentRow(
                            document: document,
                            isUnread: store.isUnread(document),
                            isBusy: downloading == document.id,
                            progress: store.downloadProgress,
                            tint: identity.start
                        )
                    }
                    .buttonStyle(LeaPressStyle())
                }
            }
            .neoCard()
        }
    }

    private func open(_ document: LeaDocument) {
        switch document.destination {
        case .externalLink:
            pendingLink = document

        case .file(let name, _, _):
            guard downloading == nil else { return }
            downloading = document.id
            downloadError = nil
            Task {
                defer { downloading = nil }
                do {
                    // The page the link was found on travels with the request:
                    // some of Léa's document handlers turn away anything that
                    // did not come from one of their own pages.
                    let url = try await store.download(
                        document,
                        from: course.section(.documents)?.url
                    )
                    openFile = LeaOpenedFile(url: url, title: name ?? document.title)
                } catch {
                    downloadError = (error as? LeaService.Failure)?.message
                        ?? error.localizedDescription
                }
            }
        }
    }
}

// MARK: - What kind of file this is

/// A file's type, as something to show rather than something to guess at.
///
/// The type is named in words as well as drawn in a colour, because "the red
/// one" is not a usable instruction for a reader who cannot see red — and a
/// student scanning for the slides wants to find them without reading eight
/// filenames.
struct DocumentKind {
    let symbol: String
    let label: String
    let tint: Color

    static func of(_ document: LeaDocument) -> DocumentKind {
        guard case .file(let name, _, let url) = document.destination else {
            return DocumentKind(
                symbol: "link",
                label: String(localized: "Link"),
                tint: .teal
            )
        }

        let candidate = (name?.isEmpty == false ? name! : url.lastPathComponent)
        switch URL(fileURLWithPath: candidate).pathExtension.lowercased() {
        case "pdf":
            return DocumentKind(symbol: "doc.richtext.fill", label: "PDF", tint: .red)
        case "doc", "docx", "rtf", "odt", "pages":
            return DocumentKind(
                symbol: "doc.text.fill",
                label: String(localized: "Document"),
                tint: .blue
            )
        case "ppt", "pptx", "key", "odp":
            return DocumentKind(
                symbol: "rectangle.on.rectangle.fill",
                label: String(localized: "Slides"),
                tint: .orange
            )
        case "xls", "xlsx", "csv", "numbers", "ods":
            return DocumentKind(
                symbol: "tablecells.fill",
                label: String(localized: "Spreadsheet"),
                tint: .green
            )
        case "mp4", "mov", "m4v", "avi", "mkv", "webm":
            return DocumentKind(
                symbol: "play.rectangle.fill",
                label: String(localized: "Video"),
                tint: .purple
            )
        case "mp3", "m4a", "wav", "aac":
            return DocumentKind(
                symbol: "waveform",
                label: String(localized: "Audio"),
                tint: .pink
            )
        case "zip", "rar", "7z":
            return DocumentKind(
                symbol: "doc.zipper",
                label: String(localized: "Archive"),
                tint: .gray
            )
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return DocumentKind(
                symbol: "photo.fill",
                label: String(localized: "Image"),
                tint: .indigo
            )
        default:
            return DocumentKind(
                symbol: "doc.fill",
                label: String(localized: "File"),
                tint: .secondary
            )
        }
    }
}

// MARK: - Row

struct LeaDocumentRow: View {
    let document: LeaDocument
    let isUnread: Bool
    let isBusy: Bool
    /// How far the download has got, when this is the row being downloaded.
    var progress: Double?
    var tint: Color = .accentColor

    private var kind: DocumentKind { DocumentKind.of(document) }

    private var isExternal: Bool {
        if case .externalLink = document.destination { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.subheadline.weight(isUnread ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = document.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                if let required = document.requiredBy {
                    Label(required, systemImage: "clock.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 6) {
                    Text(kind.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(kind.tint)

                    if case .file(_, let size, _) = document.destination, let size {
                        Text(verbatim: "·")
                        Text(size)
                    }
                    if let since = document.availableSince {
                        Text(verbatim: "·")
                        Text(since)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if !isBusy {
                Image(systemName: isExternal ? "arrow.up.right" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            // A bar across the foot of the row that is downloading, rather than
            // a spinner tucked into the corner: it says how much is left, and
            // it says it on the row the tap was aimed at.
            if isBusy {
                LeaDownloadBar(progress: progress, tint: tint)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }

    private var icon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: kind.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 38, height: 38)
                .background(
                    kind.tint.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            // Léa's own "never opened" star, as a dot. The title is bolder too,
            // so the state is never carried by the colour alone.
            if isUnread {
                Circle()
                    .fill(.red)
                    .stroke(Neo.surface, lineWidth: 2)
                    .frame(width: 11, height: 11)
                    .offset(x: 4, y: -4)
            }
        }
        .accessibilityHidden(true)
    }

    /// Read aloud as a sentence rather than as a pile of fragments.
    private var accessibilityLabel: String {
        var parts = [document.title, kind.label]
        if isUnread { parts.append(String(localized: "Not opened yet")) }
        if let required = document.requiredBy { parts.append(required) }
        if case .file(_, let size, _) = document.destination, let size { parts.append(size) }
        return parts.joined(separator: ", ")
    }
}
