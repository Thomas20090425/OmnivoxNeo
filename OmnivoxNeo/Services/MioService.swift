import Foundation
import WebKit

/// Reads MIO — OmniVox's internal messaging.
///
/// Same shape as `LeaService`, and for the same reason: MIO is reached by a
/// redirect from the portal that mints its session, so it cannot be fetched
/// with a plain request. This drives its own offscreen `WKWebView` sharing the
/// signed-in profile's cookie jar.
///
/// Separate from Léa's web view rather than borrowing it. They are two modules
/// with two sessions and two ideas of what page should currently be loaded, and
/// a mail refresh landing in the middle of a grades read is exactly the class
/// of bug that took a day to find the last time two things shared one address
/// bar.
@MainActor
final class MioService: NSObject {
    struct Failure: LocalizedError {
        let isSessionExpired: Bool
        let message: String

        var errorDescription: String? { message }

        @MainActor
        static var unavailable: Failure {
            Failure(isSessionExpired: false, message: Loc.text("Messages are not available for this account."))
        }

        @MainActor
        static var sessionExpired: Failure {
            Failure(
                isSessionExpired: true,
                message: Loc.text("Your session expired. Pull to refresh and try again.")
            )
        }

        static func unreadable(_ detail: String) -> Failure {
            Failure(isSessionExpired: false, message: detail)
        }
    }

    private let institution: Institution
    private let webView: WKWebView
    /// Shared with the compose session, which needs the same signed-in cookies
    /// in a web view of its own.
    let websiteDataStore: WKWebsiteDataStore
    private var pendingNavigation: CheckedContinuation<Void, Error>?

    /// Where MIO turned out to live, once the redirect has been followed.
    ///
    /// Everything else is built from this: it carries the college code, the
    /// language and the freshly minted `Ref` that makes a request belong to
    /// this session, none of which can be guessed.
    private(set) var moduleURL: URL?

    private var conventions: MioConventions { institution.conventions.mio }

    /// Attachments are fetched through this view, on the page they were
    /// printed on, for the reasons written up in `PortalDownloader`.
    private lazy var downloader = PortalDownloader(webView: webView)

    init(institution: Institution, websiteDataStore: WKWebsiteDataStore) {
        self.institution = institution
        self.websiteDataStore = websiteDataStore

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.applicationNameForUserAgent = AppModel.portalUserAgentProduct
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_280, height: 2_048),
            configuration: configuration
        )

        super.init()
        webView.navigationDelegate = self
    }

    /// Forgets the hop so the next read starts from the portal again.
    func invalidate() {
        moduleURL = nil
    }

    // MARK: - Reaching MIO

    /// Follows the portal's MIO shortcut, once per session.
    @discardableResult
    func openHome() async throws -> URL {
        if let moduleURL {
            try await load(moduleURL)
            if try await settles(on: conventions.readySelector) {
                return try await rememberModuleURL()
            }
            // The redirect mints a one-shot reference, so a kept address does
            // eventually stop working. Start again from the front door.
            self.moduleURL = nil
        }

        try await load(institution.portalURL)
        let href = try await string(
            #"""
            (() => {
                const link = document.querySelector(SEL_SHORTCUT);
                return link ? new URL(link.getAttribute('href'), location.href).href : '';
            })()
            """#
            .replacingOccurrences(
                of: "SEL_SHORTCUT",
                with: conventions.portalShortcutSelector.javascriptStringLiteral
            )
        )
        guard let shortcut = URL(string: href), !href.isEmpty else {
            throw Failure.unavailable
        }

        try await load(shortcut)
        _ = try await settles(on: conventions.readySelector)
        return try await rememberModuleURL()
    }

    /// Notes the address MIO actually settled on, frames and all.
    @discardableResult
    private func rememberModuleURL() async throws -> URL {
        let inner = try await string(sessionScript)
        let resolved = URL(string: inner) ?? webView.url ?? institution.portalURL
        moduleURL = resolved
        return resolved
    }

    // MARK: - Reads

    /// Which folders exist, and how much is waiting in each.
    func fetchOverview() async throws -> MioOverview {
        try await exclusive {
            try await self.openHome()
            let json = try await self.string(self.foldersScript)
            guard let payload = self.decode([FolderPayload].self, from: json) else {
                throw Failure.unreadable(Loc.text("Your folders could not be read."))
            }
            let folders = payload.map {
                MioFolder(
                    key: $0.key,
                    kind: MioFolder.Kind(rawValue: $0.kind) ?? .custom,
                    name: $0.name,
                    unreadCount: $0.count
                )
            }
            return MioOverview(folders: folders, fetchedAt: Date())
        }
    }

    /// One folder's messages.
    func fetchMessages(in folderKey: String) async throws -> MioMessageList {
        try await exclusive {
            try await self.openHome()
            guard let url = self.address(for: self.conventions.listPath, query: [
                self.conventions.folderQueryName: folderKey
            ]) else {
                throw Failure.unavailable
            }
            try await self.load(url)
            _ = try await self.settles(on: self.conventions.listTableSelector)

            let json = try await self.string(self.messagesScript)
            guard let payload = self.decode(MessageListPayload.self, from: json) else {
                throw Failure.unreadable(Loc.text("Your messages could not be read."))
            }
            guard payload.found else {
                // MIO renders its chrome and an empty middle when it does not
                // like the address. An empty folder renders the table with no
                // rows in it, so the two are told apart rather than both
                // reported as "nothing here".
                throw Failure.unreadable(Loc.text("Your messages could not be read."))
            }
            return MioMessageList(
                folderKey: folderKey,
                messages: payload.messages.map(MioService.message(from:)),
                totalText: payload.total.nilIfBlank
            )
        }
    }

    /// One message.
    ///
    /// Opening it is also what marks it read: MIO does that server-side when
    /// its detail page is fetched, which is the same thing that would happen if
    /// the student had opened it on the web. Nothing extra is sent to say so.
    func fetchMessage(token: String, in folderKey: String) async throws -> MioMessageDetail {
        try await exclusive {
            try await self.openHome()
            guard let url = self.address(for: self.conventions.detailPath, query: [
                self.conventions.messageQueryName: token,
                self.conventions.detailFolderQueryName: folderKey
            ]) else {
                throw Failure.unavailable
            }
            try await self.load(url)
            _ = try await self.settles(on: self.conventions.detailBodySelector)

            let json = try await self.string(self.messageScript)
            guard let payload = self.decode(MessagePayload.self, from: json) else {
                throw Failure.unreadable(Loc.text("This message could not be read."))
            }
            return MioMessageDetail(
                subject: payload.subject,
                sender: payload.sender.nilIfBlank,
                recipients: payload.recipients.compactMap(\.nilIfBlank),
                dateText: payload.date.nilIfBlank,
                bodyHTML: payload.body,
                // What the web view resolves a pasted picture's relative
                // address against. The page MIO actually settled on rather than
                // the one that was asked for: it redirects, and a picture
                // resolved against the wrong directory is a broken image.
                baseURL: self.webView.url ?? url,
                attachments: payload.attachments.compactMap { item in
                    guard let url = URL(string: item.url) else { return nil }
                    return MioAttachment(
                        name: item.name.nilIfBlank ?? url.lastPathComponent,
                        sizeText: item.size.nilIfBlank,
                        url: url
                    )
                },
                readReceipt: MioService.receipt(read: payload.read, total: payload.total),
                canReply: payload.canReply,
                canReplyAll: payload.canReplyAll
            )
        }
    }

    // MARK: - Flags and follow-ups

    /// Turns a message's flag, or its own "read this again" dot, on or off —
    /// and does not come back until OmniVox agrees.
    ///
    /// Done by pressing MIO's own control on its own list page, which updates
    /// the folder counts in the menu at the same time. Calling its web service
    /// directly would change the message and leave every count beside it wrong
    /// until the next refresh.
    ///
    /// The checking is the point. The first version pressed the control, waited
    /// six hundred milliseconds and reported success — and a flag set in the
    /// app was simply gone the next time the portal was opened in a browser.
    /// MIO's list is server-rendered and its handlers are attached by script
    /// afterwards, so a press that lands before that has happened does nothing
    /// at all, silently. Now it presses, waits for MIO's own mark to change,
    /// tries a different way of pressing if it does not, and then **reloads the
    /// page and looks again** — because a mark that a page flipped on its own
    /// before the server answered is not proof of anything. If the flag is not
    /// there after a fresh load, this throws and the row goes back to how it
    /// was, which is the honest outcome.
    func setIndicator(
        messageID: String,
        in folderKey: String,
        isFlag: Bool,
        to target: Bool
    ) async throws {
        try await exclusive {
            try await self.openHome()
            // The frameset, not the list page on its own. MIO's flags are
            // wired up by script that the frameset loads, so on the bare page
            // the control is there, the class is there, and nothing is
            // listening — which is exactly how a flag set in the app was gone
            // again the next time the portal was opened in a browser.
            guard let url = self.address(for: self.conventions.framesetPath, query: [
                self.conventions.folderQueryName: folderKey
            ]) else {
                throw Failure.unavailable
            }

            let wanted = target ? "on" : "off"

            func reloadList() async throws {
                try await self.load(url)
                _ = try await self.settles(on: self.conventions.listTableSelector)
                // The row is in the markup; the handler on it is not. Waiting
                // for the page to finish starting up is the difference between
                // pressing a control and pressing a picture of one.
                _ = try await self.settlesOnReadyDocument()
            }

            func currentState() async throws -> String {
                try await self.string(
                    self.indicatorStateScript(messageID: messageID, isFlag: isFlag)
                )
            }

            try await reloadList()
            guard try await currentState() != "missing" else {
                throw Failure.unreadable(Loc.text("That could not be changed right now."))
            }
            if try await currentState() == wanted { return }

            // Press it, one way at a time, and after each one load the page
            // again and look. Checking the mark on the spot proves nothing:
            // MIO updates it before it has heard back from anywhere, and the
            // way that actually works here deliberately does not update it at
            // all. A fresh page is the only answer worth believing.
            //
            // MIO's own handler goes first because it is the one that works;
            // the rest are there for a build that does not have it.
            // Bounded on purpose. Five ways of pressing a control, each with a
            // page load after it, is a minute of somebody waiting to find out
            // whether their flag took. The first one is the one that works; the
            // rest are for a build that does not have it, and they are not
            // worth an unbounded wait.
            let deadline = Date().addingTimeInterval(18)
            var confirmed = false
            for method in ["handler", "click", "rebind", "events", "inner"] {
                if Date() >= deadline { break }
                let pressed = try await self.string(
                    self.indicatorScript(messageID: messageID, isFlag: isFlag, method: method)
                )
                guard pressed == "ok" else { continue }

                // The change is a request the page makes itself; give it a
                // moment to land before asking the server what it thinks.
                try? await Task.sleep(for: .milliseconds(900))
                try await reloadList()
                if try await currentState() == wanted { confirmed = true; break }
            }

            guard confirmed else {
                #if DEBUG
                // What the page actually looked like when this failed, so the
                // next attempt at it starts from evidence.
                let report = (try? await self.string(
                    self.indicatorDiagnosticsScript(messageID: messageID, isFlag: isFlag)
                )) ?? ""
                Pasteboard.copy(report)
                #endif
                throw Failure.unreadable(Loc.text("That could not be changed right now."))
            }
        }
    }

    // MARK: - Throwing one away

    /// Deletes one message, and does not come back until MIO agrees it is gone.
    ///
    /// Done the way a student would, on MIO's own list page inside its own
    /// frameset: tick the row, press Delete, answer the box it raises. The web
    /// service behind it would be quicker and would leave every count in the
    /// folder menu wrong until the next refresh — the same reason flags go
    /// through the page rather than around it.
    ///
    /// The controls are named exactly (`#hlkDelete`, and the Yes on
    /// `confirmDelete_divConfirmNoSave`) because the version of this that tried
    /// to *recognise* them instead was a genuine hazard: MIO draws the **No**
    /// button of the delete confirmation with `mio_Supprimer.svg`, so ranking
    /// candidates by "looks like a delete" put the cancel button first and
    /// pressed it every time.
    ///
    /// Success still has to be proved, and proving it means the **count**. "The
    /// one I asked about is gone" is equally true after something emptied the
    /// whole folder. One row fewer is a delete; anything else is reported as a
    /// failure and the row goes back where it was.
    func delete(token: String, in folderKey: String) async throws {
        try await exclusive {
            try await self.openHome()
            guard let url = self.address(for: self.conventions.framesetPath, query: [
                self.conventions.folderQueryName: folderKey
            ]) else {
                throw Failure.unavailable
            }

            func reloadList() async throws {
                try await self.load(url)
                _ = try await self.settles(on: self.conventions.listTableSelector)
                // The row is in the markup long before anything is listening to
                // it. Same lesson as the flags.
                _ = try await self.settlesOnReadyDocument()
            }

            @MainActor func presence() async throws -> DeletePresence {
                let json = try await self.string(self.deletePresenceScript(token: token))
                guard let value = self.decode(DeletePresence.self, from: json) else {
                    throw Failure.unreadable(Loc.text("That message could not be deleted."))
                }
                return value
            }

            /// Why it did not work, with the page attached in a debug build so
            /// the next attempt starts from evidence rather than from a guess.
            @MainActor func failure(_ stage: String) async -> Failure {
                #if DEBUG
                let report = "stage: \(stage)\n"
                    + ((try? await self.string(self.deleteDiagnosticsScript(token: token))) ?? "")
                Pasteboard.copy(report)
                print("🗑️ MIO delete failed at: \(stage)")
                #endif
                return Failure.unreadable(Loc.text("That message could not be deleted."))
            }

            try await reloadList()
            let before = try await presence()
            // Already gone — deleted on the web, or this ran twice.
            guard before.present else { return }

            let pressed = try await self.string(self.deletePressScript(token: token))
            guard pressed == "ok" else {
                throw await failure("press:\(pressed)")
            }

            let confirmed = try await self.string(self.deleteConfirmScript(token: token))
            guard confirmed == "ok" else {
                throw await failure("confirm:\(confirmed)")
            }

            // Answering the box posts the form back. Wait for that to land
            // before asking the server what it thinks.
            try? await Task.sleep(for: .milliseconds(1_200))
            try await reloadList()

            let after = try await presence()
            guard !after.present else {
                throw await failure("still-present")
            }
            guard after.rows == before.rows - 1 else {
                // Gone, but so is something else. Never call this a success.
                throw await failure("rows:\(before.rows)->\(after.rows)")
            }
        }
    }

    // MARK: - Attachments

    /// Fetches an attachment and hands back a file on disk.
    ///
    /// The address is **re-read from a freshly loaded message**, not taken from
    /// the one the screen is holding, and the fetch runs on this web view
    /// rather than on a `URLSession` with the cookies copied across. Both of
    /// those are the hard-won lesson written up in `PortalDownloader`: the link
    /// carries a one-shot token minted by the page it was printed on, OmniVox
    /// retires it as soon as the session asks for anything else, and what comes
    /// back instead is a perfectly ordinary 200 containing a sign-out page —
    /// saved under the sender's filename, where it opens as a blank document
    /// with no error anywhere. Attachments were unopenable for exactly this
    /// reason until they were moved onto the same path Léa's documents use.
    func downloadAttachment(
        named name: String,
        token: String,
        in folderKey: String
    ) async throws -> URL {
        try await exclusive {
            try await self.openHome()
            guard let url = self.address(for: self.conventions.detailPath, query: [
                self.conventions.messageQueryName: token,
                self.conventions.detailFolderQueryName: folderKey
            ]) else {
                throw Failure.unavailable
            }
            try await self.load(url)
            _ = try await self.settles(on: self.conventions.detailBodySelector)

            let json = try await self.string(self.messageScript)
            guard let payload = self.decode(MessagePayload.self, from: json) else {
                throw Failure.unreadable(Loc.text("That file could not be downloaded."))
            }

            let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let match = payload.attachments.first(where: {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
                }) ?? payload.attachments.first,
                let link = URL(string: match.url)
            else {
                throw Failure.unreadable(Loc.text("That file could not be downloaded."))
            }

            return try await self.downloader.download(
                from: link,
                preferredName: match.name.nilIfBlank ?? wanted,
                referer: self.webView.url ?? url
            )
        }
    }

    // MARK: - Addresses

    /// Builds an address inside MIO's module, keeping the session parameters
    /// the redirect gave us and replacing only what is being asked for.
    func address(for path: String, query: [String: String]) -> URL? {
        guard
            let moduleURL,
            var components = URLComponents(url: moduleURL, resolvingAgainstBaseURL: false)
        else { return nil }

        // Everything under the module lives at the same root; only the tail
        // changes. Found rather than assumed, because a college can host the
        // module under a prefix of its own.
        guard let range = moduleURL.path.range(of: conventions.modulePathFragment) else {
            return nil
        }
        let root = String(moduleURL.path[..<range.upperBound])
        components.path = root + path

        var items = (components.queryItems ?? []).filter { item in
            // Anything being replaced goes; everything else — the college code,
            // the language, the session reference — is kept exactly as minted.
            !query.keys.contains(item.name)
                && item.name != conventions.folderQueryName
                && item.name != conventions.messageQueryName
                && item.name != conventions.detailFolderQueryName
        }
        for (name, value) in query.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        return components.url
    }

    // MARK: - Turn-taking

    private var isReading = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// One web view, one address bar: every read takes a turn.
    private func exclusive<T>(_ work: () async throws -> T) async rethrows -> T {
        if isReading {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isReading = true
        }
        defer {
            if waiting.isEmpty {
                isReading = false
            } else {
                waiting.removeFirst().resume()
            }
        }
        return try await work()
    }

    // MARK: - Navigation

    private func load(_ url: URL) async throws {
        let localized = institution.conventions.localizedPortalURL(
            url,
            languageCode: AppLanguageStore.shared.portalLanguageCode
        )
        var request = URLRequest(
            url: localized,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 30
        )
        if let header = AppLanguageStore.shared.acceptLanguageHeader {
            request.setValue(header, forHTTPHeaderField: "Accept-Language")
        }
        webView.load(request)
        try await waitForNavigation(timeout: .seconds(30))
        try await rejectSignInWall()
    }

    private func waitForNavigation(timeout: Duration) async throws {
        pendingNavigation?.resume(
            throwing: Failure.unreadable(Loc.text("The page was replaced before it finished loading."))
        )
        pendingNavigation = nil

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failPendingNavigation()
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            pendingNavigation = continuation
        }
    }

    private func failPendingNavigation() {
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        pendingNavigation.resume(
            throwing: Failure.unreadable(
                Loc.text("Messages took too long to answer. Check your connection and try again.")
            )
        )
    }

    private func finishPendingNavigation(_ result: Result<Void, Error>) {
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        pendingNavigation.resume(with: result)
    }

    /// An expired session answers with the portal's sign-in form rather than
    /// an error, so the form is what has to be recognised.
    private func rejectSignInWall() async throws {
        let isLogin = try await string(
            "(() => document.querySelector(\(institution.conventions.loginFormSelector.javascriptStringLiteral)) ? '1' : '0')()"
        )
        if isLogin == "1" {
            moduleURL = nil
            throw Failure.sessionExpired
        }
    }

    /// Whether something matching this selector is on the page yet.
    ///
    /// MIO builds itself out of frames that arrive separately, so "the
    /// navigation finished" is a long way from "the mail is there".
    private func settles(on selector: String) async throws -> Bool {
        for attempt in 0 ..< 12 {
            let found = try await string(
                "(() => DOC_FOR(\(selector.javascriptStringLiteral)).querySelector(\(selector.javascriptStringLiteral)) ? '1' : '0')()"
            )
            if found == "1" { return true }
            if attempt < 11 { try? await Task.sleep(for: .milliseconds(300)) }
        }
        return false
    }

    /// Whether every document on the page has finished starting up.
    ///
    /// "The navigation finished" and "the page's own scripts have run" are two
    /// different moments, and MIO puts its click handlers on in the second one.
    /// Anything pressed in between is pressed on markup that is not listening.
    private func settlesOnReadyDocument() async throws -> Bool {
        for attempt in 0 ..< 12 {
            let ready = try await string(
                #"""
                (() => {
                    for (const doc of DOCS(document, 0)) {
                        try {
                            if (doc.readyState !== 'complete') return '0';
                        } catch (e) { /* a frame from elsewhere; not ours to wait for */ }
                    }
                    return '1';
                })()
                """#
            )
            if ready == "1" {
                // Handlers are attached on ready, which is the tick after.
                try? await Task.sleep(for: .milliseconds(250))
                return true
            }
            if attempt < 11 { try? await Task.sleep(for: .milliseconds(250)) }
        }
        return false
    }

    // MARK: - Scripting

    private func string(_ body: String) async throws -> String {
        let expression = body.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t;"))
        let script = """
        (() => {
            const SEL = \(conventions.javascriptDescriptor);
            \(mioHelpers)
            const result = (\(expression));
            return typeof result === 'string' ? result : String(result);
        })();
        """

        do {
            let value = try await webView.evaluateJavaScript(script)
            return (value as? String) ?? ""
        } catch {
            throw Failure.unreadable(
                Loc.text("Messages could not be read: %@", error.localizedDescription)
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Mapping

    private static func message(from payload: MessagePayload.Row) -> MioMessage {
        MioMessage(
            id: payload.token,
            messageID: payload.messageID,
            isSent: payload.isSent,
            state: MioMessage.State(rawValue: payload.state) ?? .unknown,
            correspondent: MioMessage.Correspondent(rawValue: payload.correspondent) ?? .unknown,
            correspondentLabel: payload.correspondentLabel.nilIfBlank,
            name: payload.name,
            subject: payload.subject,
            preview: payload.preview,
            dateText: payload.date,
            isFlagged: payload.flagged,
            needsSecondRead: payload.followUp,
            attachmentNote: payload.attachmentNote.nilIfBlank,
            attachmentSize: payload.attachmentSize.nilIfBlank,
            category: payload.category.nilIfBlank,
            readReceipt: receipt(read: payload.read, total: payload.total),
            openURL: payload.open.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        )
    }

    private static func receipt(read: Int?, total: Int?) -> MioReadReceipt? {
        guard let read, let total, total > 0 else { return nil }
        return MioReadReceipt(read: read, total: total)
    }
}

// MARK: - WKNavigationDelegate

extension MioService: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.finishPendingNavigation(.success(())) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in self?.finishPendingNavigation(.failure(error)) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in self?.finishPendingNavigation(.failure(error)) }
    }
}

// MARK: - Wire shapes
//
// Flat and all-strings on purpose: the page prints text, and a decoder that
// insists on richer types fails the whole read because one row had something in
// it nobody expected.

/// Whether a message is still in the list, and how long the list is.
private struct DeletePresence: Decodable {
    let present: Bool
    let rows: Int
}

private struct FolderPayload: Decodable {
    let key: String
    let kind: String
    let name: String
    let count: Int?
}

private struct MessageListPayload: Decodable {
    let found: Bool
    let messages: [MessagePayload.Row]
    let total: String
}

private struct MessagePayload: Decodable {
    struct Row: Decodable {
        let token: String
        let messageID: String
        let isSent: Bool
        let state: String
        let correspondent: String
        let correspondentLabel: String
        let name: String
        let subject: String
        let preview: String
        let date: String
        let flagged: Bool
        let followUp: Bool
        let attachmentNote: String
        let attachmentSize: String
        let category: String
        let open: String?
        let read: Int?
        let total: Int?
    }

    struct Attachment: Decodable {
        let name: String
        let size: String
        let url: String
    }

    let subject: String
    let sender: String
    let recipients: [String]
    let date: String
    let body: String
    let attachments: [Attachment]
    let read: Int?
    let total: Int?
    let canReply: Bool
    let canReplyAll: Bool
}
