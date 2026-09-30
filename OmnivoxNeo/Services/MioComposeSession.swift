import Combine
import Foundation
import WebKit

/// One message being written, and the live MIO page behind it.
///
/// Writing needs a page that stays put — MIO keeps the draft, the recipients
/// and the attachments in server-side state belonging to one open form — so
/// this owns a web view of its own rather than taking turns on the one the
/// lists are read through. A refresh arriving mid-sentence must not be able to
/// navigate away from what somebody is typing.
///
/// Almost all of it is native. The exception is choosing who a brand-new
/// message goes to: MIO's recipient picker is its own search over the whole
/// college directory, opened in a pop-up, and re-implementing it would mean
/// guessing at an address this app has never been shown. Replying, replying to
/// all and forwarding need none of it, because MIO fills the recipients in
/// itself — which is why those are native from end to end.
@MainActor
final class MioComposeSession: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case opening
        case ready
        case sending
        case sent
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Who MIO says this is going to. Read back from its own form rather than
    /// tracked here: the picker is the authority on that list.
    @Published private(set) var recipients: [String] = []
    @Published var draft = MioDraft()
    /// True while MIO's own recipient picker is the thing on screen.
    @Published private(set) var isPickingRecipients = false
    /// Whichever of the picker's screens is showing, read into something the
    /// app can draw itself. Nil means it has not been read yet.
    @Published private(set) var picker: MioPickerPage?
    /// The picker's own window, kept because a college whose build this app
    /// does not recognise still has to be usable.
    @Published private(set) var pickerWebView: WKWebView?
    @Published private(set) var pickerFailure: String?

    /// What is being typed, with its formatting. Turned into HTML on the way
    /// out; MIO stores HTML, so this is the shape the message really is.
    #if canImport(UIKit)
    @Published var bodyText = NSAttributedString(string: "")
    #endif

    /// MIO's upload window, and what it has been given so far.
    @Published private(set) var uploadWebView: WKWebView?
    @Published private(set) var attachments: [MioComposeAttachment] = []
    @Published private(set) var isAttaching = false

    /// Whether there is anything written, whichever editor this platform has.
    var hasBody: Bool {
        #if canImport(UIKit)
        return !bodyText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #else
        return !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #endif
    }

    var hasContent: Bool {
        hasBody || !draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bodyHTML: String {
        #if canImport(UIKit)
        return RichTextHTML.html(from: bodyText)
        #else
        return RichTextHTML.html(fromPlain: draft.body)
        #endif
    }

    private let institution: Institution
    private unowned let service: MioService
    private var pendingNavigation: CheckedContinuation<Void, Error>?

    private var conventions: MioConventions { institution.conventions.mio }

    /// The page itself, for the one screen that has to show it.
    let webView: WKWebView

    init(institution: Institution, service: MioService) {
        self.institution = institution
        self.service = service

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = service.websiteDataStore
        configuration.applicationNameForUserAgent = AppModel.portalUserAgentProduct
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 1_400),
            configuration: configuration
        )

        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    // MARK: - Opening

    /// Opens MIO's own compose form for this intent and reads back what it
    /// filled in — the recipients and the quoted original, for a reply.
    func start(_ intent: MioDraft.Intent) async {
        draft.intent = intent
        phase = .opening

        guard let url = composeURL(for: intent) else {
            phase = .failed(Loc.text("Messages are not available for this account."))
            return
        }

        do {
            try await load(url)
            let state = try await readState()
            recipients = state.recipients
            draft.recipients = state.recipients
            if draft.subject.isEmpty { draft.subject = state.subject }
            // MIO quotes the original itself for a reply. Kept as its own
            // field so the student writes above it rather than into it.
            if draft.body.isEmpty, !state.body.isEmpty, intent.action != nil {
                draft.body = ""
            }
            phase = state.ready ? .ready : .failed(Loc.text("This message could not be started."))
        } catch {
            phase = .failed((error as? MioService.Failure)?.message ?? error.localizedDescription)
        }
    }

    private func composeURL(for intent: MioDraft.Intent) -> URL? {
        var query: [String: String] = [:]
        if let action = intent.action { query[conventions.composeActionQueryName] = action }
        if let id = intent.messageID { query[conventions.composeMessageQueryName] = id }
        return service.address(for: conventions.composePath, query: query)
    }

    // MARK: - Recipients

    /// Opens MIO's own picker in a window of its own, and waits for it.
    ///
    /// The window matters. MIO opens the picker with `window.open` and then
    /// talks back to the form through `window.opener` when the student saves:
    /// it fills in the names, posts the form back, and closes itself. This used
    /// to answer that request by loading the picker *into* the same web view,
    /// which is tidy right up until Save — at which point the form it wanted to
    /// talk to had been replaced by the picker itself, `window.opener` was
    /// nothing, and the page sat on "Please wait…" forever with no error and no
    /// way forward. A real child web view, built from the configuration WebKit
    /// hands over, keeps that relationship intact.
    func beginPickingRecipients() async {
        pickerFailure = nil

        // Held up for the *whole* sequence, not just the window opening.
        //
        // Reopening the directory reads the page, then walks back up to the
        // menu — and MIO fills in who is already chosen somewhere in the
        // middle of that. Showing the screen before it finishes meant the
        // student's first sight of it was "Nobody yet. Pick somebody below."
        // over a list that did in fact have them on it, which reads as the app
        // having lost the recipient they just added.
        pickerActivity = Loc.text("Opening the directory…")
        defer { pickerActivity = nil }

        // Still open from last time. MIO focuses the window it already has
        // rather than opening a second one, so asking again produced nothing
        // to wait for and the app reported that the directory could not be
        // opened — from then on, permanently.
        if pickerWebView != nil {
            isPickingRecipients = true
            await refreshPicker(settling: true)
            return
        }

        picker = nil

        // Closing the picker posts the form back, so for a moment afterwards
        // the control that opens it is part of a page being replaced. Asked
        // for more than once rather than once, because the failure mode was
        // the worst kind: the button did nothing, said nothing, and the
        // student concluded they could not add anybody else at all.
        var opened = false
        for attempt in 0 ..< 3 {
            if (try? await string(service.composeOpenPickerScript)) == "ok" {
                opened = true
                break
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        guard opened else {
            pickerFailure = Loc.text("The directory could not be opened.")
            return
        }
        isPickingRecipients = true

        // The window arrives through the delegate rather than from this call,
        // so this waits for it instead of assuming.
        for _ in 0 ..< 30 {
            if pickerWebView != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard pickerWebView != nil else {
            isPickingRecipients = false
            pickerFailure = Loc.text("The directory could not be opened.")
            return
        }
        await refreshPicker(settling: true)

        // MIO reopens the picker wherever it was last left — on the search
        // page, or halfway into a class list — because that state is its own
        // and outlives the window. Opening on "I wish to add…" every time is
        // what makes the button mean one thing; walked back rather than reset,
        // so the people already chosen stay chosen.
        for _ in 0 ..< 4 {
            guard let page = picker, page.mode != .chooser, page.canGoBack else { break }
            await pickerGoBack()
        }
    }

    /// Re-reads whichever of the picker's screens is showing.
    ///
    /// `settling` waits out the post-back MIO does for almost every tap: its
    /// pages are ASP.NET update panels, so choosing a class or running a search
    /// replaces the panel a moment later and reading too early returns the
    /// screen the student just left.
    func refreshPicker(settling: Bool = false) async {
        guard pickerWebView != nil else { return }
        if settling {
            for _ in 0 ..< 20 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let page = await readPicker() else { continue }
                if !page.isBusy, page.isNative { picker = page; return }
                picker = page
            }
            return
        }
        if let page = await readPicker() { picker = page }
    }

    private func readPicker() async -> MioPickerPage? {
        guard let json = try? await pickerString(service.pickerScript) else { return nil }
        guard
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(PickerPayload.self, from: data)
        else { return nil }
        return payload.page
    }

    /// Presses something the native screen drew — an option, a person, a class.
    ///
    /// The name travels with the handle so a node MIO has redrawn since can
    /// still be found. Without it, taking a recipient back off the list was a
    /// button that did nothing.
    func pickerTap(_ ref: String, named name: String = "") async {
        guard !ref.isEmpty || !name.isEmpty else { return }
        await working(Loc.text("Adding %@…", name.nilIfBlank ?? Loc.text("this person"))) {
            _ = try? await pickerString(service.pickerClickScript(ref: ref, name: name))
            await refreshPicker(settling: true)
        }
    }

    /// Takes somebody back off the list of people this is going to.
    ///
    /// Not the same call as adding them, which is what it used to be. In the
    /// results a person is the control; in the panel of people already chosen
    /// the name is a label and the cross beside it is the control, so pressing
    /// the name did nothing whatsoever — and nothing said so, which is why the
    /// only way to remove anybody was to abandon the message.
    ///
    /// Each way of pressing is followed by re-reading MIO's own panel. A
    /// removal that cannot be proved is reported rather than assumed.
    func pickerRemove(_ person: MioPickerPage.Chosen) async {
        // Not `pickerFailure`: that one replaces the whole screen with "the
        // directory could not be opened", and a removal that did not take is
        // no reason to throw away a directory that plainly did open.
        pickerNotice = nil

        // The one thing the directory cannot do, established by testing it
        // rather than by assuming it: MIO hands the form its choice through a
        // field called `hidAjoutDestinataires` — *add* recipients — and its
        // Save treats "nobody selected" as "nothing to add" and leaves the
        // form exactly as it was. Taking one of several people off works and
        // is verified; taking the **last** one off silently does nothing, and
        // the name is still in the To field afterwards.
        //
        // So it is not attempted. Ten seconds of spinner followed by the name
        // reappearing is the worst possible answer, and the way round it is
        // one sentence long: add the replacement first, then remove this one.
        // Nobody ever wants an empty recipient list as an end state anyway —
        // a message with nobody on it cannot be sent.
        if (picker?.chosen.count ?? 0) <= 1 {
            say(Loc.text(
                "A message needs at least one person. Add someone else first, then remove %@.",
                person.name
            ))
            return
        }

        // Everybody else currently on the list, so the script can refuse to
        // press a control that might belong to one of them.
        let others = (picker?.chosen ?? [])
            .map(\.name)
            .filter { $0 != person.name }

        var ambiguous = false
        await working(Loc.text("Removing %@…", person.name)) {
            for method in ["control", "item", "events"] {
                let pressed = try? await pickerString(
                    service.pickerRemoveScript(
                        ref: person.id,
                        name: person.name,
                        others: others,
                        method: method
                    )
                )
                // The container that holds this person also holds somebody
                // else, so there is no control here that is provably theirs.
                // Pressing anyway is how the wrong person came off the list.
                if pressed == "ambiguous" { ambiguous = true; break }
                guard pressed == "ok" else { continue }
                await refreshPicker(settling: true)
                guard picker?.chosen.contains(where: { $0.name == person.name }) == true else { return }
            }
        }
        // Gone. Nothing to report.
        if picker?.chosen.contains(where: { $0.name == person.name }) != true { return }

        #if DEBUG
        // What MIO actually drew, so the control can be named properly rather
        // than guessed at a fourth time.
        Pasteboard.copy((try? await pickerString(service.pickerSelectionDiagnosticsScript)) ?? "")
        #endif

        // Told apart on purpose. "Nothing here is provably this person's
        // control" and "the press did not take" are different problems, and
        // only one of them is worth trying again.
        say(ambiguous
            ? Loc.text("%@ could not be removed here. Close the directory, open it again, then try.", person.name)
            : Loc.text("%@ is still on the list. Give it a moment, then try again.", person.name))
    }

    /// Something that did not work, said in place.
    ///
    /// Short-lived and beside the thing it is about, unlike `pickerFailure`,
    /// which is for a directory that never opened at all and takes the screen.
    ///
    /// Set through `say(_:)` rather than directly, so it goes away on its own.
    @Published var pickerNotice: String?

    private var noticeToken = UUID()

    /// Says something, and takes it back down again.
    ///
    /// A message that stays until the next one is a message that is still on
    /// screen three screens later, attached to nothing.
    private func say(_ message: String) {
        pickerNotice = message
        let token = UUID()
        noticeToken = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard let self, self.noticeToken == token else { return }
            self.pickerNotice = nil
        }
    }

    /// What MIO is doing, while it does it.
    ///
    /// Every one of these is a round trip to the college through a web view —
    /// a search is a page load, and so is adding one person to a list. Several
    /// seconds of a screen that looks finished is how somebody presses the same
    /// name twice, and two presses on a list MIO is halfway through redrawing
    /// is how the wrong person comes off it.
    @Published private(set) var pickerActivity: String?

    private func working<T>(_ what: String, _ body: () async -> T) async -> T {
        pickerActivity = what
        defer { pickerActivity = nil }
        return await body()
    }

    /// Runs MIO's own search with what was typed into the native field.
    func pickerSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await working(Loc.text("Searching…")) {
            _ = try? await pickerString(service.pickerSearchScript(text: trimmed))
            await refreshPicker(settling: true)
        }
    }

    /// Changes one of MIO's own term or campus menus.
    func pickerFilter(_ ref: String, to value: String) async {
        await working(Loc.text("Updating the list…")) {
            _ = try? await pickerString(service.pickerFilterScript(ref: ref, value: value))
            await refreshPicker(settling: true)
        }
    }

    /// Presses MIO's own save, which is what hands the names back to the form.
    ///
    /// Returns false when this college's picker does not have a control this
    /// app recognises — in which case the caller shows MIO's own page rather
    /// than leaving the student with a button that does nothing.
    @discardableResult
    func commitPicker() async -> Bool {
        guard pickerWebView != nil else { return false }
        // Marked before the picker saves, so the post-back that replaces the
        // form can be recognised for what it is rather than waited out.
        let stamp = await stampForm()
        let result = try? await pickerString(service.pickerCommitScript)
        guard result == "ok" else { return false }
        // MIO closes its own window once it has posted back. Waiting for that
        // is what tells the difference between "saved" and "still saving".
        for _ in 0 ..< 40 {
            if pickerWebView == nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await finishPickingRecipients(awaitingReplacementOf: stamp)
        return true
    }

    /// Writes a one-off marker onto the compose document.
    ///
    /// MIO hands the choice back by posting the form, which builds a whole new
    /// document — so the marker being gone is proof that the page in hand is
    /// the new one. Reading the recipients without that proof is reading the
    /// page from *before* the change, which is exactly how a recipient the
    /// student had just removed came straight back.
    private func stampForm() async -> String {
        let token = UUID().uuidString
        let script = "(() => { window.__neoFormStamp = \(token.javascriptStringLiteral); return 'ok'; })()"
        guard (try? await string(script)) == "ok" else { return "" }
        return token
    }

    private func formStamp() async -> String {
        (try? await string("(() => String(window.__neoFormStamp || ''))()")) ?? ""
    }

    /// Goes back to the menu of ways to find somebody, keeping the choices
    /// made so far — they live on MIO's side, not this app's.
    func pickerGoBack() async {
        await working(Loc.text("Going back…")) {
            _ = try? await pickerString(service.pickerBackScript)
            await refreshPicker(settling: true)
        }
    }

    /// Abandons the picker without saving.
    func cancelPicker() async {
        _ = try? await pickerString(service.pickerCancelScript)
        closePicker()
        await finishPickingRecipients()
    }

    /// Every control on the picker page, for finding out what a college's own
    /// build calls its save button. Debug builds only.
    func pickerControls() async -> String {
        (try? await pickerString(service.pickerControlsScript)) ?? ""
    }

    /// The compose form's recipients row, for the same reason.
    func composeOutline() async -> String {
        (try? await string(service.composeRecipientsOutlineScript)) ?? ""
    }

    private func closePicker() {
        pickerWebView?.uiDelegate = nil
        pickerWebView = nil
        picker = nil
        isPickingRecipients = false
    }

    /// Called once the picker is gone: MIO has posted back with whatever was
    /// chosen, so the form is asked again rather than guessed at.
    /// Called once the picker is gone: MIO has posted back with whatever was
    /// chosen, so the form is asked again rather than guessed at.
    ///
    /// It used to stop at the first read that came back with anybody in it,
    /// which is wrong twice over. Early in the post-back the page in hand is
    /// still the one from before, so that read returns the *old* list — and if
    /// the student had just taken their only recipient off, "anybody in it"
    /// was never going to become true, so it sat through the whole timeout and
    /// then reported the name they had just removed. That is the several
    /// seconds of nothing followed by the name coming back.
    ///
    /// Now it waits for the marker put on the old document to disappear, which
    /// is the post-back actually landing, and reads once afterwards. An empty
    /// list is an answer.
    func finishPickingRecipients(awaitingReplacementOf stamp: String? = nil) async {
        closePicker()

        if let stamp, !stamp.isEmpty {
            var replaced = false
            for _ in 0 ..< 24 {
                try? await Task.sleep(for: .milliseconds(250))
                if await formStamp() != stamp { replaced = true; break }
            }
            // Whether or not it was seen to land, the new page needs a moment
            // to finish drawing the row this is about to read.
            if replaced { try? await Task.sleep(for: .milliseconds(250)) }
        }

        // Retried only against a read that failed outright — an empty list is
        // a real answer and must not be waited out.
        for attempt in 0 ..< 4 {
            if let state = try? await readState() {
                recipients = state.recipients
                draft.recipients = state.recipients
                return
            }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(300)) }
        }
    }

    // MARK: - Attaching a file

    /// Opens MIO's own upload window.
    ///
    /// Its own, because uploading is not a form post — the page slices the file
    /// into ten-megabyte chunks, streams them to a handler with a token of its
    /// own, and only then submits. Re-implementing that is a great deal of work
    /// to arrive at exactly what MIO already does; what is worth replacing is
    /// everything *around* it, which is why the window closes itself and hands
    /// back a list of files the app draws.
    func beginAttaching() async {
        guard (try? await string(service.composeAttachScript)) == "ok" else { return }
        isAttaching = true
        for _ in 0 ..< 30 {
            if uploadWebView != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if uploadWebView == nil { isAttaching = false }
    }

    /// Called when that window goes away — by uploading, or by cancelling.
    func finishAttaching() async {
        uploadWebView?.uiDelegate = nil
        uploadWebView = nil
        isAttaching = false
        // MIO posts the form back after an upload, so the answer is not there
        // the instant the window closes.
        for _ in 0 ..< 12 {
            await refreshAttachments()
            if !attachments.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    func refreshAttachments() async {
        guard let json = try? await string(service.composeAttachmentsScript) else { return }
        guard
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode([AttachmentPayload].self, from: data)
        else { return }
        attachments = payload.map {
            MioComposeAttachment(id: $0.ref, name: $0.name, sizeText: $0.size, removeID: $0.remove.nilIfBlank)
        }
    }

    /// Takes a file back off, when MIO offers a way to.
    func removeAttachment(_ attachment: MioComposeAttachment) async {
        guard let removeID = attachment.removeID else { return }
        _ = try? await string(service.composeClickScript(ref: removeID))
        try? await Task.sleep(for: .milliseconds(900))
        await refreshAttachments()
    }

    // MARK: - Sending

    /// Puts the student's words into MIO's form and presses its own Send.
    ///
    /// MIO's own button, not a rebuilt post: the page validates, strips images
    /// it will not carry, cancels its auto-save and disables itself first, and
    /// a hand-made post-back skips every one of those.
    func send() async {
        guard phase == .ready else { return }
        phase = .sending

        do {
            let filled = try await string(
                service.composeFillScript(
                    subject: draft.subject,
                    bodyHTML: bodyHTML,
                    hidesRecipients: draft.hidesRecipients
                )
            )
            guard filled != "missing" else {
                phase = .failed(Loc.text("This message could not be sent."))
                return
            }

            let pressed = try await string(service.composeSendScript)
            if pressed == "disabled" {
                // MIO's own answer to "not ready yet", said in its own words
                // rather than reported as a failure.
                phase = .failed(Loc.text("Choose who this goes to before sending."))
                return
            }
            guard pressed == "ok" else {
                phase = .failed(Loc.text("This message could not be sent."))
                return
            }

            // MIO answers with its own confirmation panel rather than a new
            // page, so the wait is for that rather than for a navigation.
            for _ in 0 ..< 30 {
                try? await Task.sleep(for: .milliseconds(400))
                if let result = try? await string(service.composeConfirmationScript),
                   result == "sent" {
                    phase = .sent
                    return
                }
            }
            // No confirmation, but also no error: MIO sometimes navigates
            // straight back to the list instead. Treated as sent, because the
            // alternative is telling a student their message failed when it did
            // not and having them send it twice.
            phase = .sent
        } catch {
            phase = .failed((error as? MioService.Failure)?.message ?? error.localizedDescription)
        }
    }

    /// Saves what is written as a draft and leaves it there.
    func saveDraft() async {
        guard phase == .ready || phase == .sending else { return }
        _ = try? await string(
            service.composeFillScript(
                subject: draft.subject,
                bodyHTML: bodyHTML,
                hidesRecipients: draft.hidesRecipients
            )
        )
        _ = try? await string(
            #"""
            (() => {
                const doc = DOC_FOR(SEL.composeSaveDraft);
                for (const candidate of SEL.composeSaveDraft.split(',')) {
                    const button = doc.querySelector(candidate.trim());
                    if (button) { button.click(); return 'ok'; }
                }
                return 'missing';
            })()
            """#
        )
        try? await Task.sleep(for: .milliseconds(800))
    }

    /// Plain text as the HTML MIO stores.
    ///
    /// MIO keeps message bodies as HTML and re-sends them as HTML, so text
    /// pasted in raw arrives at the other end as one unbroken paragraph. The
    /// escaping is not decoration: a student writing "marks < 60" would
    /// otherwise lose the rest of the sentence to an unclosed tag.
    static func html(from text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return escaped
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? "<div><br></div>" : "<div>\($0)</div>" }
            .joined()
    }

    // MARK: - Plumbing

    private struct State: Decodable {
        let ready: Bool
        let subject: String
        let recipients: [String]
        let body: String
        let canSend: Bool
    }

    private func readState() async throws -> State {
        let json = try await string(service.composeStateScript)
        guard
            let data = json.data(using: .utf8),
            let state = try? JSONDecoder().decode(State.self, from: data)
        else {
            return State(ready: false, subject: "", recipients: [], body: "", canSend: false)
        }
        return state
    }

    private func load(_ url: URL) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
        if let header = AppLanguageStore.shared.acceptLanguageHeader {
            request.setValue(header, forHTTPHeaderField: "Accept-Language")
        }
        webView.load(request)
        try await waitForNavigation()
        // The form is built by script after the document lands.
        for _ in 0 ..< 12 {
            if let state = try? await readState(), state.ready { return }
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    private func waitForNavigation() async throws {
        pendingNavigation?.resume(throwing: CancellationError())
        pendingNavigation = nil

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.failPending()
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            pendingNavigation = continuation
        }
    }

    private func failPending() {
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        pendingNavigation.resume(
            throwing: MioService.Failure.unreadable(
                Loc.text("Messages took too long to answer. Check your connection and try again.")
            )
        )
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let pendingNavigation else { return }
        self.pendingNavigation = nil
        pendingNavigation.resume(with: result)
    }

    private func string(_ body: String) async throws -> String {
        try await evaluate(body, in: webView)
    }

    /// The same, against the picker's own window.
    private func pickerString(_ body: String) async throws -> String {
        guard let pickerWebView else { return "" }
        return try await evaluate(body, in: pickerWebView)
    }

    private func evaluate(_ body: String, in target: WKWebView) async throws -> String {
        let expression = body.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t;"))
        let script = """
        (() => {
            const SEL = \(conventions.javascriptDescriptor);
            \(service.mioHelpers)
            const result = (\(expression));
            return typeof result === 'string' ? result : String(result);
        })();
        """
        let value = try await target.evaluateJavaScript(script)
        return (value as? String) ?? ""
    }
}

// MARK: - Wire shape for the picker

private struct AttachmentPayload: Decodable {
    let ref: String
    let name: String
    let size: String
    let remove: String
}

private struct PickerPayload: Decodable {
    struct Option: Decodable {
        let id: String
        let title: String
        let group: String
    }

    struct Person: Decodable {
        let id: String
        let name: String
        let detail: String
        let section: String?
        let correspondent: String
    }

    struct Group: Decodable {
        let id: String
        let title: String
        let subtitle: String
        let isExpanded: Bool
        let expandID: String
        let addAllID: String
        let addAllTitle: String
        let members: [Person]
        let emptyNote: String
    }

    struct Filter: Decodable {
        struct Choice: Decodable {
            let id: String
            let title: String
        }

        let id: String
        let label: String
        let selection: String
        let choices: [Choice]
    }

    struct Chosen: Decodable {
        let id: String
        let name: String
        let section: String
    }

    let mode: String
    let title: String?
    let instructions: String?
    let options: [Option]?
    let groups: [Group]?
    let filters: [Filter]?
    let results: [Person]?
    let searchLabel: String?
    let searchText: String?
    let hasSearched: Bool?
    let emptyNote: String?
    let overflowNote: String?
    let chosen: [Chosen]?
    let warning: String?
    let isBusy: Bool?
    let canCommit: Bool?
    let canGoBack: Bool?

    var page: MioPickerPage {
        MioPickerPage(
            mode: MioPickerPage.Mode(rawValue: mode) ?? .unknown,
            title: title ?? "",
            instructions: instructions ?? "",
            options: (options ?? []).map {
                MioPickerPage.Option(id: $0.id, title: $0.title, group: $0.group)
            },
            groups: (groups ?? []).map { group in
                MioPickerPage.Group(
                    id: group.id,
                    title: group.title,
                    subtitle: group.subtitle,
                    isExpanded: group.isExpanded,
                    expandID: group.expandID.nilIfBlank,
                    addAllID: group.addAllID.nilIfBlank,
                    addAllTitle: group.addAllTitle,
                    members: group.members.map(PickerPayload.person(from:)),
                    emptyNote: group.emptyNote
                )
            },
            filters: (filters ?? []).map { filter in
                MioPickerPage.Filter(
                    id: filter.id,
                    label: filter.label,
                    selection: filter.selection,
                    choices: filter.choices.map {
                        MioPickerPage.Filter.Choice(id: $0.id, title: $0.title)
                    }
                )
            },
            results: (results ?? []).map(PickerPayload.person(from:)),
            searchLabel: searchLabel ?? "",
            searchText: searchText ?? "",
            hasSearched: hasSearched ?? false,
            emptyNote: emptyNote ?? "",
            overflowNote: overflowNote ?? "",
            chosen: (chosen ?? []).map {
                MioPickerPage.Chosen(id: $0.id, name: $0.name, section: $0.section)
            },
            warning: warning ?? "",
            isBusy: isBusy ?? false,
            canCommit: canCommit ?? false,
            canGoBack: canGoBack ?? false
        )
    }

    private static func person(from payload: Person) -> MioPickerPage.Person {
        MioPickerPage.Person(
            id: payload.id,
            name: payload.name,
            detail: payload.detail,
            section: payload.section ?? "",
            correspondent: MioMessage.Correspondent(rawValue: payload.correspondent) ?? .unknown
        )
    }
}

extension MioComposeSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.finish(.success(())) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }
}

extension MioComposeSession: WKUIDelegate {
    /// MIO opens its recipient picker with `window.open`, and then talks back
    /// to the form through `window.opener` when the student saves.
    ///
    /// So it gets a real window. This has to be a new web view built from the
    /// configuration WebKit hands over — that configuration is what carries the
    /// opener relationship — and it has to be returned from this call rather
    /// than made later, because WebKit is asking for it now.
    ///
    /// Loading the picker into the *existing* web view instead, which is what
    /// this did before, is tidier and completely broken: by the time the
    /// student pressed Save, the form the picker wanted to fill in had been
    /// replaced by the picker, `window.opener` was nothing, and MIO sat on
    /// "Please wait…" with no error and nowhere to go.
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            let child = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 1_024, height: 1_400),
                configuration: configuration
            )
            // Its own UI delegate so it can ask to be closed, and no navigation
            // delegate at all: this session's one belongs to the form, and
            // letting the picker's page loads resolve the form's continuation
            // is how a reply ends up reading the directory as its own body.
            child.uiDelegate = self

            // Two different windows arrive through this one method — the
            // directory and the file uploader — and they are completely
            // different screens. Told apart by where they are going.
            let address = navigationAction.request.url?.absoluteString ?? ""
            if address.contains(conventions.composeUploadPathFragment) {
                uploadWebView = child
                isAttaching = true
            } else {
                pickerWebView = child
                isPickingRecipients = true
            }
            return child
        }
    }

    /// MIO closes the picker itself once it has posted the names back.
    nonisolated func webViewDidClose(_ webView: WKWebView) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.uploadWebView === webView {
                await self.finishAttaching()
            } else if self.pickerWebView === webView {
                await self.finishPickingRecipients()
            }
        }
    }
}
