import Combine
import PDFKit
import QuickLook
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// A file that has been fetched out of Léa and is ready to read.
struct LeaOpenedFile: Identifiable, Hashable {
    let url: URL
    let title: String

    var id: String { url.absoluteString }
}

/// Reader state for one opened file. Léa holds this only while that file is
/// selected, allowing the PDF view to be rebuilt across a width change
/// without losing the page or the current search.
@MainActor
final class LeaReaderSession: ObservableObject {
    let file: LeaOpenedFile
    let pdfDocument: PDFDocument?

    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var isSearching = false
    @Published var query = ""
    @Published var matchCount = 0
    @Published var matchIndex = 0

    init(file: LeaOpenedFile) {
        self.file = file
        // Léa sometimes names a non-PDF download `.pdf`; loading the document
        // is the actual format check, and happens just once for this route.
        pdfDocument = file.url.pathExtension.lowercased() == "pdf"
            ? PDFDocument(url: file.url)
            : nil
    }
}

/// The app's own reader for course documents.
///
/// Built rather than handed to `QLPreviewController` for PDFs specifically,
/// because the things a student does with a set of slides — jump pages, search
/// the text, share it to a study group, print it — are worth having in one
/// place that matches the rest of the app. Anything that is not a PDF still
/// goes to Quick Look, which already knows every other format Léa serves.
///
/// Read-only for now: annotating a teacher's handout is a genuinely different
/// feature, with its own storage and its own questions about what happens to
/// the marks when the teacher reposts the file.
struct LeaFileReaderView: View {
    let file: LeaOpenedFile
    @StateObject private var session: LeaReaderSession

    init(file: LeaOpenedFile, session: LeaReaderSession? = nil) {
        self.file = file
        _session = StateObject(wrappedValue: session ?? LeaReaderSession(file: file))
    }

    /// A PDF this app can actually open.
    ///
    /// Checked by loading it, not by trusting the extension: Léa names its
    /// downloads `.pdf` whether or not what came back is one, and a `PDFView`
    /// handed something else draws a blank page with no complaint. A file that
    /// fails here goes to Quick Look, which handles far more formats — and if
    /// that cannot read it either, the screen says so instead of staying empty.
    private var isPDF: Bool { session.pdfDocument != nil }

    var body: some View {
        Group {
            if let document = session.pdfDocument {
                PDFReader(
                    document: document,
                    query: session.query,
                    matchIndex: session.matchIndex,
                    currentPage: $session.currentPage,
                    pageCount: $session.pageCount,
                    matchCount: $session.matchCount
                )
                .ignoresSafeArea(edges: .bottom)
            } else if canPreview {
                // Word, PowerPoint, Excel, Pages, Keynote, images, video:
                // Quick Look already reads every format Léa serves, and
                // renders them the way the rest of iOS does.
                QuickLookPreview(url: file.url)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                unreadable
            }
        }
        .navigationTitle(file.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Reading a set of slides should get the whole screen, and the tab bar
        // is not somewhere to go from here.
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: file.url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            #if os(iOS)
            if isPDF {
                // A search field that only appears when asked for keeps the
                // page itself full-width, but it needs something to ask
                // with: as a pushed screen there is no search bar sitting
                // under the title waiting to be tapped.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        session.isSearching = true
                    } label: {
                        Label("Search in document", systemImage: "magnifyingglass")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        print(file: file.url, title: file.title)
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                }
            }
            #endif

            if isPDF {
                ToolbarItem(placement: .status) {
                    if session.query.isEmpty {
                        if session.pageCount > 0 {
                            Text("\(session.currentPage) / \(session.pageCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        searchControls
                    }
                }
            }
        }
        .onChange(of: session.query) { _, _ in session.matchIndex = 0 }
        .searchable(
            text: $session.query,
            isPresented: $session.isSearching,
            placement: .toolbar,
            prompt: Text("Search in document")
        )
    }

    /// "3 of 12", and the two arrows that make the count worth printing.
    ///
    /// Selecting the first hit and stopping — which is all this used to do —
    /// looks identical to doing nothing when the first hit is already on
    /// screen, which is most of the time. Every match is highlighted, the
    /// arrows step between them, and the count says whether there is anything
    /// to step to.
    @ViewBuilder
    private var searchControls: some View {
        if session.matchCount == 0 {
            Text("No matches")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 14) {
                Button {
                    session.matchIndex = (session.matchIndex - 1 + session.matchCount) % session.matchCount
                } label: {
                    Image(systemName: "chevron.up")
                }
                .accessibilityLabel("Previous match")

                // `fixedSize` because the status slot will otherwise squeeze
                // the count down to nothing between the two arrows, which
                // leaves a pair of chevrons and no sense of how far they go.
                Text("\(session.matchIndex + 1) of \(session.matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Button {
                    session.matchIndex = (session.matchIndex + 1) % session.matchCount
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel("Next match")
            }
            .font(.footnote.weight(.semibold))
        }
    }

    /// Whether the system can show this at all.
    private var canPreview: Bool {
        #if os(iOS)
        QLPreviewController.canPreview(file.url as NSURL)
        #else
        true
        #endif
    }

    /// The honest dead end, with the two ways out that still work.
    ///
    /// The old screen showed a blank white page here, which reads as "the app
    /// is broken" when the truth is "this is a format iOS cannot draw" — and
    /// left the student with nothing to do about it. Sharing it to an app that
    /// *can* open it is a real answer.
    private var unreadable: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label("Can’t Preview This File", systemImage: "doc.questionmark")
            } description: {
                Text("\(file.url.lastPathComponent) isn’t a format this app can show. You can still open it in another app or save it.")
            }

            ShareLink(item: file.url) {
                Label("Open in Another App", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: 320)
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NeoBackground())
    }

    #if os(iOS)
    private func print(file url: URL, title: String) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = title
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true, completionHandler: nil)
    }
    #endif
}

// MARK: - PDF

#if canImport(UIKit)
private struct PDFReader: UIViewRepresentable {
    let document: PDFDocument
    let query: String
    let matchIndex: Int
    @Binding var currentPage: Int
    @Binding var pageCount: Int
    @Binding var matchCount: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        // Grouped rather than plain, so the page edges are visible against the
        // surround in both light and dark.
        view.backgroundColor = .secondarySystemBackground
        view.document = document

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        context.coordinator.view = view
        context.coordinator.preserveInitialPage = !query.isEmpty

        if currentPage > 1, document.pageCount > 0,
           let page = document.page(at: min(currentPage, document.pageCount) - 1) {
            view.go(to: page)
        }

        DispatchQueue.main.async {
            pageCount = view.document?.pageCount ?? 0
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        let coordinator = context.coordinator

        if coordinator.lastQuery != query {
            coordinator.lastQuery = query

            guard !query.isEmpty, let document = view.document else {
                coordinator.matches = []
                view.highlightedSelections = nil
                view.setCurrentSelection(nil, animate: false)
                coordinator.lastIndex = -1
                DispatchQueue.main.async { matchCount = 0 }
                return
            }

            let found = document.findString(query, withOptions: [.caseInsensitive])
            coordinator.matches = found

            // Every hit is tinted at once. Without this the only feedback was
            // a text selection that is invisible when the match was already on
            // screen — which read, fairly, as the search doing nothing at all.
            for match in found { match.color = .systemYellow.withAlphaComponent(0.45) }
            view.highlightedSelections = found.isEmpty ? nil : found

            coordinator.lastIndex = -1
            DispatchQueue.main.async { matchCount = found.count }
        }

        guard !coordinator.matches.isEmpty else { return }
        let target = min(max(matchIndex, 0), coordinator.matches.count - 1)
        guard coordinator.lastIndex != target else { return }
        coordinator.lastIndex = target

        // The one being looked at is selected as well as highlighted, so it
        // stands out from the others, and the page is brought to it.
        let match = coordinator.matches[target]
        if coordinator.preserveInitialPage {
            // Reconstituting the PDF view after a fold should not jump back to
            // the selected search hit if the reader had scrolled elsewhere.
            coordinator.preserveInitialPage = false
            view.setCurrentSelection(match, animate: false)
        } else {
            view.setCurrentSelection(match, animate: true)
            view.go(to: match)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPage: $currentPage)
    }

    final class Coordinator: NSObject {
        weak var view: PDFView?
        var lastQuery = ""
        var matches: [PDFSelection] = []
        var lastIndex = -1
        var preserveInitialPage = false
        private let currentPage: Binding<Int>

        init(currentPage: Binding<Int>) {
            self.currentPage = currentPage
        }

        @objc func pageChanged(_ notification: Notification) {
            guard
                let view,
                let document = view.document,
                let page = view.currentPage
            else { return }
            currentPage.wrappedValue = document.index(for: page) + 1
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#else
private struct PDFReader: View {
    let document: PDFDocument
    let query: String
    let matchIndex: Int
    @Binding var currentPage: Int
    @Binding var pageCount: Int
    @Binding var matchCount: Int

    var body: some View {
        Text(document.documentURL?.lastPathComponent ?? "")
    }
}

private struct QuickLookPreview: View {
    let url: URL
    var body: some View { Text(url.lastPathComponent) }
}
#endif
