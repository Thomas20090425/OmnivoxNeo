import Combine
import SwiftUI
import WebKit

/// What came of opening the feedback form.
///
/// There is deliberately no `.submitted` case reached on faith. BugDrop raises
/// no event when a report is sent, so the only thing the app genuinely knows is
/// that the form closed — and, when the confirmation screen showed a link to
/// the new issue, which issue it was. Anything stronger would be the app
/// telling somebody their report landed without having checked.
enum FeedbackSubmissionOutcome {
    case cancelled
    case closed(issue: Int?)
}

/// Sending a bug report or a feature request.
///
/// The form is a web page rather than native screens, for one reason that is
/// worth the trade: filing a GitHub issue needs a key that can write to the
/// repository, and a key inside a shipped app is a key everybody has. BugDrop
/// holds that key on its own server and files the issue on the student's
/// behalf, so this app never holds one — and the cost is that the form itself
/// is somebody else's HTML.
///
/// Which makes the isolation the important part. The web view gets a
/// `nonPersistent` data store, created fresh here and thrown away with the
/// sheet, so it shares nothing with the portal session: no cookies, no
/// credentials, no storage, nothing about the student's college account. It is
/// allowed to show exactly one address, and any link out of it leaves for the
/// browser instead of opening inside.
struct FeedbackSubmissionView: View {
    let onFinish: (FeedbackSubmissionOutcome) -> Void

    @StateObject private var bridge = FeedbackWebBridge()
    @Environment(\.openURL) private var openURL
    @ObservedObject private var language = AppLanguageStore.shared
    @State private var hasOpenedForm = false

    var body: some View {
        NavigationStack {
            Group {
                if hasOpenedForm {
                    form
                } else {
                    introduction
                }
            }
            .background(NeoBackground())
            // Not "Send Feedback": that is the heading BugDrop puts on its own
            // form, and two of them stacked reads as a mistake.
            .navigationTitle("Feedback")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(.cancelled) }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
        .onAppear {
            bridge.load(
                pageURL: CommunityFeedbackService.feedbackPageURL,
                version: AppRelease.version,
                accent: Personalization.shared.accent.color,
                prefersFrench: language.effectiveLanguageCode.hasPrefix("fr")
            )
        }
        .onChange(of: bridge.closedWithIssue) { _, closed in
            guard let closed else { return }
            onFinish(.closed(issue: closed.issueNumber))
        }
    }

    // MARK: - What they are agreeing to, before anything loads

    private var introduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tell me what is wrong, or what is missing")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The form asks for a short description and whether it is a bug or a request. That is all it asks for.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    point(
                        systemImage: "globe",
                        title: "What you write becomes public",
                        detail: "It is posted as an issue on GitHub, where anyone can read it. Do not include your password, your student number or your grades."
                    )
                    point(
                        systemImage: "person.crop.circle.dashed",
                        title: "Your name is optional",
                        detail: "There is a name box and leaving it empty is normal. Whatever you type in it is published with the report, so a first name or a nickname is plenty."
                    )
                    point(
                        systemImage: "lock.shield",
                        title: "Nothing from your account goes with it",
                        detail: "This form runs in its own window with no access to your Omnivox session, your timetable, your grades or your messages. Your app version is attached, and nothing else is."
                    )
                    point(
                        systemImage: "camera",
                        title: "The screenshot option is not useful here",
                        detail: "It can only photograph the form itself, not the screen the problem was on. Untick it and describe what you saw instead."
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neoCard()

                // Withdrawn entirely once loading has failed, rather than left
                // on screen to be pressed into a broken page. What replaces it
                // is a way to get the form anyway.
                if !bridge.hasFailed {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { hasOpenedForm = true }
                        bridge.openForm()
                    } label: {
                        Text("Open the Feedback Form")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!bridge.isReady)
                }

                statusLine
            }
            .padding(16)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var statusLine: some View {
        if bridge.hasFailed {
            VStack(alignment: .leading, spacing: 8) {
                Text("The form could not be loaded. It needs a connection, and it is the one part of this app that does.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open It in a Browser") {
                    openURL(CommunityFeedbackService.feedbackPageURL)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !bridge.isReady {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the form…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Nothing is sent until you fill the form in and press Submit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func point(
        systemImage: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Neo.accent)
                .frame(width: 22)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The form itself

    private var form: some View {
        FeedbackWebView(bridge: bridge)
            .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - The web view, and the only two things it is allowed to do

/// Owns the web view, drives the form, and listens for it closing.
@MainActor
final class FeedbackWebBridge: NSObject, ObservableObject {
    /// Carries the issue number out, and is a fresh value every time so
    /// `onChange` fires even for two closes in a row.
    struct Close: Equatable {
        let issueNumber: Int?
        let id = UUID()
    }

    @Published private(set) var isReady = false
    @Published private(set) var hasFailed = false
    @Published private(set) var closedWithIssue: Close?

    private(set) lazy var webView: WKWebView = makeWebView()
    private var pageHost: String?
    private var hasLoaded = false
    private var watchdog: Task<Void, Never>?

    /// How long the form gets to say it is ready before the sheet stops
    /// waiting and offers a browser instead.
    ///
    /// Needed because a web view can load something perfectly well and still
    /// never become the thing that was asked for — a captive portal, a cached
    /// error page, a page whose script was blocked. Without this the sheet
    /// would sit on "Loading the form…" with a dead button, which is the worst
    /// of the possible failures: it looks like the app is still trying.
    private static let readyTimeout: Duration = .seconds(12)

    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        controller.add(self, name: "omnivoxNeo")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Thrown away with this object. The portal's cookies live in a
        // different store entirely and were never reachable from here, but a
        // store that cannot outlive the sheet cannot leak into the next one
        // either.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        return webView
    }

    /// Loads the published feedback page, telling it the few things it needs.
    ///
    /// Everything is passed in the URL fragment rather than the query string.
    /// A fragment is not sent to the server, so none of it reaches GitHub
    /// Pages or its access log — which matters less for a version number than
    /// for the habit.
    func load(pageURL: URL, version: String, accent: Color, prefersFrench: Bool) {
        guard !hasLoaded else { return }
        hasLoaded = true
        pageHost = pageURL.host?.lowercased()

        var fragment = [
            "embedded=1",
            "lang=\(prefersFrench ? "fr" : "en")"
        ]
        if let encoded = version.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) {
            fragment.append("v=\(encoded)")
        }
        if let hex = Self.hexString(for: accent) {
            fragment.append("accent=\(hex)")
        }

        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        // `percentEncodedFragment`, not `fragment`. The pieces above are
        // already encoded — the accent arrives as `%23RRGGBB` because a bare
        // `#` would end the fragment — and assigning to `fragment` encodes
        // them a second time, turning `%23` into `%2523`. The page then sees
        // `%23007AFF` where it expects `#007AFF`, rejects it as malformed, and
        // falls back to BugDrop's default colour. Same for the version.
        components?.percentEncodedFragment = fragment.joined(separator: "&")
        webView.load(URLRequest(url: components?.url ?? pageURL))

        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.readyTimeout)
            guard !Task.isCancelled, let self, !self.isReady else { return }
            self.hasFailed = true
        }
    }

    /// Stops waiting — the form answered, one way or the other.
    fileprivate func settle(ready: Bool) {
        watchdog?.cancel()
        watchdog = nil
        if ready {
            isReady = true
            hasFailed = false
        } else {
            hasFailed = true
        }
    }

    /// Asks the page to put the form on screen.
    func openForm() {
        webView.evaluateJavaScript(
            "window.omnivoxNeoOpenFeedback && window.omnivoxNeoOpenFeedback();"
        )
    }

    /// `%23RRGGBB`, so the form arrives in the colour the student chose for
    /// the rest of the app rather than BugDrop's default teal.
    private static func hexString(for color: Color) -> String? {
        #if canImport(UIKit)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        #else
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let red = converted.redComponent
        let green = converted.greenComponent
        let blue = converted.blueComponent
        #endif
        let clamp = { (value: CGFloat) in Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "%%23%02X%02X%02X", clamp(red), clamp(green), clamp(blue))
    }
}

// MARK: - What the page is allowed to say

extension FeedbackWebBridge: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let host = message.frameInfo.securityOrigin.host.lowercased()
        let isMainFrame = message.frameInfo.isMainFrame
        let body = message.body as? [String: Any]

        Task { @MainActor in
            // Only the page this sheet loaded, and only its top frame. A
            // message handler is a door into the app from whatever the web
            // view happens to be showing, and the widget's own iframes have no
            // business using it.
            guard isMainFrame, host == pageHost, let body else { return }

            switch body["event"] as? String {
            case "ready":
                settle(ready: true)
            case "failed", "slow":
                settle(ready: false)
            case "closed":
                let number = body["issue"] as? Int
                closedWithIssue = Close(issueNumber: number.flatMap { $0 > 0 ? $0 : nil })
            default:
                break
            }
        }
    }
}

extension FeedbackWebBridge: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let host = url?.host?.lowercased()
        let isLink = navigationAction.navigationType == .linkActivated

        Task { @MainActor in
            // The sheet shows one page. A link in it — the privacy policy, the
            // issue that was just created, BugDrop's own site — is a different
            // page, and it belongs in a browser rather than in a window the
            // student cannot navigate.
            if isLink || (host != nil && host != pageHost) {
                if let url, url.scheme == "https" || url.scheme == "http" {
                    #if os(iOS)
                    UIApplication.shared.open(url)
                    #else
                    NSWorkspace.shared.open(url)
                    #endif
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    /// Catches the failure that does not look like one.
    ///
    /// A 404 from GitHub Pages is a *successful* navigation — the server
    /// answers, with its own error page — so none of the `didFail` callbacks
    /// ever run and the sheet would wait for a form that is never coming. The
    /// status code is the only place that shows up.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let isMainFrame = navigationResponse.isForMainFrame
        let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode

        Task { @MainActor in
            if isMainFrame, let status, !(200..<300).contains(status) {
                settle(ready: false)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in settle(ready: false) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in settle(ready: false) }
    }
}

// MARK: - Putting it on screen

private struct FeedbackWebView: PlatformViewRepresentable {
    let bridge: FeedbackWebBridge

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { bridge.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #endif
}
