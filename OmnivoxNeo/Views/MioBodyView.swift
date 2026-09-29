import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

private extension String {
    /// Drops trailing characters from a set — the full stop at the end of a
    /// sentence that happens to finish with an address.
    func trimmingTrailing(in characters: String) -> String {
        var copy = self
        while let last = copy.last, characters.contains(last) {
            copy.removeLast()
        }
        return copy
    }
}

/// The body of a message, drawn as the document it actually is.
///
/// This used to be a `Text` built from an imported `NSAttributedString`, which
/// cost two things that turn out to matter a great deal:
///
/// **Pictures.** Staff paste charts and screenshots into the middle of a MIO,
/// and MIO stores them as `<img src="ReadImageAttachement.ashx?Info=…">` — a
/// *relative* address, behind the signed-in session. An attributed string has
/// nowhere to resolve that against and no cookies to fetch it with, so the
/// picture simply was not there: the paragraph before it and the paragraph
/// after it, and in between, nothing. For a message whose entire content is a
/// chart, the app was showing an empty envelope.
///
/// **Copying a sentence.** A `Text` is one object, so selecting inside it gives
/// you the whole message or none of it. Real text selection — a word, a phone
/// number, a room code — comes free here.
///
/// The trade is that this is a web view, so it is treated like one: scripts in
/// message content are turned off, links are handed back to the app rather than
/// followed in place, and the typography is overridden to the app's own so a
/// teacher's hard-coded black text is still readable at night.
struct MioBodyView: View {
    let html: String
    /// The page this message was read from — what a relative `src` is resolved
    /// against. Without it the pictures are addressed to nowhere.
    let baseURL: URL?
    let websiteDataStore: WKWebsiteDataStore

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var height: CGFloat = 40

    var body: some View {
        MioHTMLView(
            html: Self.document(body: Self.linkified(html)),
            baseURL: baseURL,
            websiteDataStore: websiteDataStore,
            height: $height,
            onLink: { openURL($0) }
        )
        .frame(height: height)
        // The web view holds its own selection and gesture state, so it is
        // rebuilt rather than updated when the reader changes something that
        // changes the whole page.
        .id("\(colorScheme)-\(dynamicTypeSize)")
        .accessibilityLabel(Text("Message"))
    }

    /// Turns addresses a sender typed as plain text into links.
    ///
    /// Staff paste a room booking form or a Teams invitation into a MIO without
    /// making it a link — MIO's editor only links what somebody deliberately
    /// linked — and what arrives is an address you cannot tap, in a message you
    /// cannot easily select from. This finds the ones that are unmistakably
    /// addresses and marks them up.
    ///
    /// Done on the HTML rather than on the text, and deliberately shy: anything
    /// already inside a tag or already inside an anchor is left exactly alone,
    /// because linking the inside of an `href` is how a message turns into
    /// garbage.
    static func linkified(_ html: String) -> String {
        let pattern = #"(?<![\w@./:-])((?:https?://|www\.)[^\s<>"']{3,}|[\w.+-]+@[\w-]+\.[\w.-]{2,})"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
            return html
        }

        // Split on tags so only the text between them is ever touched, and
        // skip everything from an opening <a> to its closing tag.
        var result = ""
        var index = html.startIndex
        var insideAnchor = 0

        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                result += insideAnchor > 0 ? String(html[index...]) : link(html[index...], expression)
                break
            }
            let text = html[index ..< open]
            result += insideAnchor > 0 ? String(text) : link(text, expression)

            guard let close = html[open...].firstIndex(of: ">") else {
                result += String(html[open...])
                break
            }
            let tag = html[open ... close]
            let lowered = tag.lowercased()
            if lowered.hasPrefix("<a") { insideAnchor += 1 }
            if lowered.hasPrefix("</a") { insideAnchor = max(0, insideAnchor - 1) }
            result += String(tag)
            index = html.index(after: close)
        }
        return result
    }

    private static func link(_ text: Substring, _ expression: NSRegularExpression) -> String {
        let string = String(text)
        guard !string.isEmpty else { return string }
        let whole = NSRange(string.startIndex ..< string.endIndex, in: string)
        var out = ""
        var cursor = string.startIndex

        for match in expression.matches(in: string, options: [], range: whole) {
            guard let range = Range(match.range, in: string) else { continue }
            out += string[cursor ..< range.lowerBound]
            let found = String(string[range])
            // Trailing punctuation belongs to the sentence, not to the address.
            let trimmed = found.trimmingTrailing(in: ".,;:!?)]}\"'")
            let tail = found.dropFirst(trimmed.count)
            let destination: String
            if trimmed.contains("@"), !trimmed.lowercased().hasPrefix("http") {
                destination = "mailto:" + trimmed
            } else if trimmed.lowercased().hasPrefix("www.") {
                destination = "https://" + trimmed
            } else {
                destination = trimmed
            }
            out += "<a href=\"\(destination)\">\(trimmed)</a>\(tail)"
            cursor = range.upperBound
        }
        out += string[cursor...]
        return out
    }

    /// Wraps MIO's stored fragment in a document that behaves.
    ///
    /// Everything here is a correction to something MIO's own HTML assumes:
    /// that the page is white, that 12px is a reasonable size for a person to
    /// read, and that there are 900 pixels of width to lay a pasted table out
    /// in. The last one is why `img` and `table` are capped — a chart pasted
    /// from a spreadsheet is 1,400 points wide and would otherwise be shown at
    /// its own size with the message scrolled off the side of the screen.
    private static func document(body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
        :root { color-scheme: light dark; }
        html, body {
            margin: 0; padding: 0;
            background: transparent;
            color: -apple-system-label;
            font: -apple-system-body;
            -webkit-text-size-adjust: none;
            overflow-wrap: break-word;
            word-break: break-word;
        }
        /* MIO's own editor writes colours and sizes onto every run. Left alone,
           a teacher's black-on-white signature is black on near-black at night,
           and their 14px body text ignores the reader's chosen size entirely. */
        /* Block-level backgrounds go — a teacher's white page behind white
           text is unreadable at night. Inline ones stay, because those are
           somebody deliberately highlighting a sentence, and wiping them
           meant a highlighted message arrived looking untouched. */
        body * { color: inherit !important; }
        body div, body p, body table, body td, body tr, body body, body section {
            background-color: transparent !important;
        }
        body [style*="font-size"], body font[size] { font-size: inherit !important; }
        /* After the rule above and more specific than it, or the sweep that
           rescues a teacher's black-on-white text from a dark background takes
           the links down with it and every address in the message renders as
           plain body text. Underlined as well as tinted, because colour on its
           own is not something everyone can see. */
        body a, body a * {
            color: -apple-system-blue !important;
            text-decoration: underline;
        }
        img { max-width: 100% !important; height: auto !important; border-radius: 6px; }
        table { max-width: 100% !important; width: auto !important; border-collapse: collapse; }
        td, th { padding: 2px 6px; }
        blockquote {
            margin: 0 0 0 10px; padding-left: 10px;
            border-left: 3px solid -apple-system-gray;
        }
        pre { white-space: pre-wrap; }
        </style>
        </head><body>\(body)</body></html>
        """
    }
}

// MARK: - The web view itself

private struct MioHTMLView: PlatformViewRepresentable {
    let html: String
    let baseURL: URL?
    let websiteDataStore: WKWebsiteDataStore
    @Binding var height: CGFloat
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, baseURL: baseURL, onLink: onLink)
    }

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The same jar the message was fetched with, or the pictures inside it
        // come back as sign-in pages.
        configuration.websiteDataStore = websiteDataStore
        configuration.applicationNameForUserAgent = AppModel.portalUserAgentProduct
        // Nothing in a message body has any business running code. This does
        // not stop the app's own `evaluateJavaScript`, which is what measures
        // the page.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        #if canImport(UIKit)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // It lays out at its full height inside the app's own scroll view, so
        // one flick carries the reader past the end of a long message instead
        // of stopping dead at the edge of a box.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        return webView
    }

    private func update(_ webView: WKWebView, context: Context) {
        // The environment's opener is captured per render; the coordinator
        // outlives the render that made it.
        context.coordinator.onLink = onLink
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    #if canImport(UIKit)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    #endif

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        private let height: Binding<CGFloat>
        /// Kept as a variable, not a constant: the environment's opener is a
        /// value captured per render, and the coordinator outlives the render
        /// that made it.
        var onLink: (URL) -> Void

        /// The page the message was loaded against. Its own document load
        /// arrives here carrying this address, and must not be mistaken for
        /// somebody tapping a link to it.
        let baseURL: URL?

        init(height: Binding<CGFloat>, baseURL: URL?, onLink: @escaping (URL) -> Void) {
            self.height = height
            self.baseURL = baseURL
            self.onLink = onLink
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self] in self?.measureRepeatedly(webView) }
        }

        /// Measures again as the pictures arrive.
        ///
        /// The document is laid out long before an inline chart has been
        /// fetched, so a single measurement reserves the height of the text
        /// alone and clips the picture off the bottom. There is no event to
        /// wait for — a `ResizeObserver` would be page script, which is off on
        /// purpose — so it is asked again a few times over the next few
        /// seconds, and every round counts.
        ///
        /// It deliberately does *not* stop early once two answers agree, which
        /// is what the first version did and why an entire message rendered as
        /// the word "Hello,". At `didFinish` the view has not been laid out
        /// yet, so it is still the height it was given to start with — and two
        /// readings of *that* in a row look exactly like a settled measurement.
        @MainActor
        private func measureRepeatedly(_ webView: WKWebView) {
            Task { @MainActor [weak self] in
                for delay in [50, 150, 300, 600, 1_000, 1_800, 3_000] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard let self else { return }
                    // A document laid out in a view with no width has no
                    // meaningful height to report either.
                    guard webView.bounds.width > 1 else { continue }
                    let measured = await Self.contentHeight(of: webView)
                    guard measured > 1 else { continue }
                    if abs(measured - self.height.wrappedValue) > 0.5 {
                        self.height.wrappedValue = measured
                    }
                }
            }
        }

        /// How tall the message actually is.
        ///
        /// The body's own scroll height rather than the document element's:
        /// the document element is never shorter than the window, so asking it
        /// inside a view that has been given a starting height answers with
        /// that height and nothing else. The scroll view's content size is
        /// taken as well and the larger wins, so the measurement does not rest
        /// on one mechanism being available.
        private static func contentHeight(of webView: WKWebView) async -> CGFloat {
            var height: CGFloat = 0
            let value = try? await webView.evaluateJavaScript(
                "Math.ceil(document.body ? document.body.scrollHeight : 0)"
            )
            if let number = value as? NSNumber {
                height = CGFloat(truncating: number)
            }
            #if canImport(UIKit)
            height = max(height, webView.scrollView.contentSize.height)
            #endif
            return height
        }

        /// A link in a message goes wherever links go in this app: out, to the
        /// browser, rather than replacing the message with whatever it points
        /// at and leaving no way back.
        ///
        /// Decided by **where it is going**, not by how WebKit classified the
        /// tap. This used to hand over only navigations reported as
        /// `linkActivated` and allow everything else — so a link reported as
        /// anything else was loaded *inside* the message card instead, which
        /// from the reader's side is a link that does nothing at all. The only
        /// navigation this view ever legitimately performs is the one that put
        /// the message there, and that one carries no address of its own.
        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = (url.scheme ?? "").lowercased()

            // The message's own document load comes through here too, carrying
            // the page it was loaded against — and cancelling *that* is how
            // opening any message threw the reader out into Safari on the
            // OmniVox page instead of showing the message. It is told apart by
            // being the load of the base address itself, and by not being a tap.
            let isOwnContent = scheme.isEmpty
                || scheme == "about" || scheme == "data" || scheme == "file"
                || (navigationAction.navigationType != .linkActivated
                    && url.absoluteString == baseURL?.absoluteString)

            guard !isOwnContent else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            // Opened directly rather than through the environment's opener,
            // which is a value captured per render and quietly does nothing
            // when the view that captured it has gone.
            #if canImport(UIKit)
            UIApplication.shared.open(url)
            #else
            onLink(url)
            #endif
        }
    }
}
