import SwiftUI
import WebKit

/// The college's own page, shown inside the app, because the college is the
/// only one who can clear it.
///
/// This is deliberately not a rewritten version of that page. What the college
/// asks for changes without notice — a photo today, an agreement next term —
/// and a native screen guessing at it would be wrong the first time it changed.
/// The page is already loaded in the session the app signed in with, so it is
/// simply shown: its own controls, its own wording, its own submission.
///
/// What the app does take away is the portal's navigation bar, which from in
/// here only offers ways to get lost — Quit, and a link out to the college's
/// public website.
struct SchoolInterceptionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header

            InterceptionWebView(webView: model.webView)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// A line of the app's own, above the college's page.
    ///
    /// Without it this reads as the app having dumped the student into a
    /// browser with no explanation. It says who is asking and why the app has
    /// stepped out of the way, and then gets out of the way itself.
    private var header: some View {
        VStack(spacing: 6) {
            Text("\(model.institution.displayName) needs something from you")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("You are signed in. Finish this below and the app will carry on by itself.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Shows the session's own web view, rather than building a second one.
///
/// It has to be this one: the interception is bound to the signed-in session,
/// and a fresh web view would arrive at it as a stranger.
private struct InterceptionWebView: PlatformViewRepresentable {
    let webView: WKWebView

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #endif
}
