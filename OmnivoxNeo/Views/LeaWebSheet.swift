import Combine
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
    @ObservedObject var session: LeaAssignmentWebSession

    var body: some View {
        LeaWebContainer(session: session)
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
            if session.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Neo.accent)
            }
        }
        .navigationTitle(session.page.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // An upload form wants the whole screen, and the tab bar is not
        // somewhere to go from the middle of handing something in.
        .toolbar(.hidden, for: .tabBar)
        #endif
    }
}

/// Owned by the selected submission route rather than either navigation
/// container. A fold replaces the container, but not this live form. Leaving
/// the route releases it; only the profile's normal cookie store is shared.
@MainActor
final class LeaAssignmentWebSession: NSObject, ObservableObject, WKNavigationDelegate {
    let page: LeaWebPage
    let webView: WKWebView
    @Published private(set) var isLoading = true
    #if canImport(UIKit)
    weak var activeHost: UIView?
    #endif

    init(page: LeaWebPage, hiddenSelector: String, websiteDataStore: WKWebsiteDataStore) {
        self.page = page
        let configuration = WKWebViewConfiguration()
        // The same cookie jar as everything else, so the page opens signed in
        // instead of bouncing to a login form inside a sheet.
        configuration.websiteDataStore = websiteDataStore
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

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: page.url))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

#if canImport(UIKit)
private struct LeaWebContainer: UIViewRepresentable {
    let session: LeaAssignmentWebSession

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        session.activeHost = host
        attachWebView(to: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        if session.activeHost === host, session.webView.superview !== host {
            attachWebView(to: host)
        }
    }

    private func attachWebView(to host: UIView) {
        // SwiftUI can briefly own both layout branches during a transition.
        // It retires the old host while the browser itself stays in the
        // profile-scoped route session and moves to the new host.
        let webView = session.webView
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(webView)
    }
}
#else
private struct LeaWebContainer: View {
    let session: LeaAssignmentWebSession

    var body: some View {
        Link(destination: session.page.url) { Text(session.page.url.absoluteString) }
    }
}
#endif

/// Existing profile cookie-store handoff from `HomeView`. Assignment forms
/// now receive the current profile's store directly and never keep their
/// live web view in this shared object.
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
