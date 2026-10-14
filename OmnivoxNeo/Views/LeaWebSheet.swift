import SwiftUI
import WebKit

/// A Léa page the app shows rather than reads.
struct LeaWebPage: Identifiable, Hashable {
    let url: URL
    let title: String

    var id: String { url.absoluteString }
}

/// Léa's own assignment page, shown in place.
///
/// The instructions and the upload form live on the same ASP.NET page, and the
/// upload half is not something to re-implement: Léa enforces file types,
/// sizes, deadlines and a confirmation step, and a native form that disagreed
/// with any of that would fail a submission a student believed had gone
/// through. The file picker comes from the page's own `<input type="file">`,
/// which WebKit hands to the system — so this needs no photo or files
/// permission of its own, and the app never sees the file.
///
/// The page's own Close button is hidden: it posts back to a pop-up that does
/// not exist here, and two ways out that behave differently is worse than one.
struct LeaWebSheet: View {
    // Observed so a change of accent redraws this screen. `Neo.accent`
    // is a static read, which SwiftUI cannot see as a dependency.
    @ObservedObject private var accentStore = Personalization.shared
    @ObservedObject var model: AppModel
    @ObservedObject var store: LeaStore
    let page: LeaWebPage

    @State private var isLoading = true

    var body: some View {
        LeaWebContainer(
            url: page.url,
            hiddenSelector: model.institution.conventions.lea.assignmentCloseButtonSelector,
            isLoading: $isLoading
        )
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Neo.accent)
            }
        }
        .navigationTitle(page.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // An upload form wants the whole screen, and the tab bar is not
        // somewhere to go from the middle of handing something in.
        .toolbar(.hidden, for: .tabBar)
        #endif
        .onDisappear {
            // Anything handed in while this was open changed the list behind
            // it, so it is refetched rather than left claiming the assignment
            // is still outstanding.
            store.refresh()
        }
    }
}

#if canImport(UIKit)
private struct LeaWebContainer: UIViewRepresentable {
    let url: URL
    let hiddenSelector: String
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The same cookie jar as everything else, so the page opens signed in
        // instead of bouncing to a login form inside a sheet.
        configuration.websiteDataStore = context.coordinator.dataStore
        configuration.applicationNameForUserAgent = AppModel.portalUserAgentProduct

        let hide = WKUserScript(
            source: """
            (() => {
                const style = document.createElement('style');
                style.textContent = \(hiddenSelector.cssHidingRule);
                document.documentElement.appendChild(style);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(hide)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let dataStore: WKWebsiteDataStore
        private let isLoading: Binding<Bool>

        init(isLoading: Binding<Bool>) {
            self.isLoading = isLoading
            dataStore = LeaWebSession.shared.dataStore ?? .default()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            isLoading.wrappedValue = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            isLoading.wrappedValue = false
        }
    }
}
#else
private struct LeaWebContainer: View {
    let url: URL
    let hiddenSelector: String
    @Binding var isLoading: Bool

    var body: some View {
        Link(destination: url) { Text(url.absoluteString) }
    }
}
#endif

/// Where the profile's cookie jar is parked so a sheet can reach it.
///
/// `UIViewRepresentable.Coordinator` is built before the view has an
/// environment, so the store is handed over when the profile's model is made
/// rather than looked up on demand.
@MainActor
final class LeaWebSession {
    static let shared = LeaWebSession()
    private(set) var dataStore: WKWebsiteDataStore?

    func adopt(_ store: WKWebsiteDataStore) {
        dataStore = store
    }
}

private extension String {
    /// This selector as the body of a CSS rule that hides it, quoted for
    /// embedding in a script.
    var cssHidingRule: String {
        let rule = "\(self) { display: none !important; }"
        guard
            let data = try? JSONSerialization.data(withJSONObject: [rule], options: []),
            let json = String(data: data, encoding: .utf8),
            json.count >= 2
        else {
            return "''"
        }
        return String(json.dropFirst().dropLast())
    }
}
