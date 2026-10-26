import SwiftUI
import WebKit

/// Which document, in which language.
///
/// Carried in the bundle rather than fetched. Apple wants the licence and the
/// privacy policy readable inside the app, and wants every link in a
/// submission to work — so a document that is only on a website is a document
/// that is missing whenever there is no signal, and a link to a page that is
/// not published yet is a rejection rather than a placeholder.
enum LegalDocument: String, Identifiable, CaseIterable {
    case eula
    case privacy

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .eula: "End User Licence Agreement"
        case .privacy: "Privacy Policy"
        }
    }

    /// The copy matching the language the app is being shown in, falling back
    /// to English — which is the language the agreement is written in, so a
    /// missing translation shows the real terms rather than nothing.
    func fileURL(preferringFrench wantsFrench: Bool) -> URL? {
        let stem = rawValue == "eula" ? "eula" : "privacy"
        let candidates = wantsFrench ? ["\(stem)-fr", "\(stem)-en"] : ["\(stem)-en"]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "html") {
                return url
            }
        }
        return nil
    }
}

/// One legal document, shown as the website shows it.
///
/// The same HTML that is published, so the words a student agreed to in the
/// app and the words anybody can read on the web are the same words, and are
/// obviously the same words.
struct LegalDocumentSheet: View {
    let document: LegalDocument

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = AppLanguageStore.shared

    private var fileURL: URL? {
        document.fileURL(
            preferringFrench: language.effectiveLanguageCode.hasPrefix("fr")
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let fileURL {
                    LocalDocumentWebView(fileURL: fileURL)
                } else {
                    // Should not happen — the files ship in the bundle — but a
                    // blank sheet would be the worst possible way to find out.
                    ContentUnavailableView(
                        "Not Available",
                        systemImage: "doc.questionmark",
                        description: Text("This document could not be opened on this device.")
                    )
                }
            }
            .navigationTitle(document.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
        }
    }
}

private struct LocalDocumentWebView: PlatformViewRepresentable {
    let fileURL: URL

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A legal document has nothing to run and nothing to store. Turning
        // both off means this sheet cannot become a way into anything else.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Read access is granted to the containing folder so the stylesheet
        // beside the document resolves, and to nothing wider.
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return webView
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #endif
}
