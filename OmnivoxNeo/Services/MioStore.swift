import Combine
import Foundation
import WebKit

/// Everything the messaging screens read from, and the only thing that talks to
/// `MioService`.
///
/// Loaded on the same schedule as Léa and for the same reason: mail has unread
/// counts, the tab wants a badge before anyone looks at it, and both are read
/// after the timetable has settled so opening the app is not held up by either.
@MainActor
final class MioStore: ObservableObject {
    @Published private(set) var overview: MioLoadable<MioOverview> = .idle
    @Published private(set) var lists: [String: MioLoadable<MioMessageList>] = [:]
    @Published private(set) var messages: [String: MioLoadable<MioMessageDetail>] = [:]

    /// Which folder the screen is showing.
    @Published var selectedFolderKey: String

    /// What the student has typed into the search field.
    ///
    /// Filtering happens here rather than through MIO's own search, which is a
    /// post-back, a page reload and a second and a bit of waiting per keystroke.
    /// MIO's search is still reachable for the messages this one cannot see —
    /// the ones further back than the folder's first page.
    @Published var query: String = ""

    /// Messages opened in this app since the last refresh.
    ///
    /// MIO clears its own "new" mark server-side when the message is fetched,
    /// but the list in memory still says otherwise until the next refresh, so
    /// the mark is cleared here too rather than lying until then.
    @Published private(set) var locallyRead: Set<String> = []

    /// Flags and follow-ups the student has just toggled, while MIO catches up.
    @Published private(set) var pendingIndicators: Set<String> = []

    /// The last thing that happened, for saying so.
    ///
    /// Flags and read-again marks change something on OmniVox's side, and until
    /// now the only evidence either way was the icon — which changed instantly
    /// whether or not anything had actually happened, and changed back a few
    /// seconds later if it had not. That is the worst of both: it looks like it
    /// worked, and then quietly unlooks. The row still changes immediately,
    /// because waiting two seconds for a flag is its own kind of broken, but
    /// the app now goes and checks, and says which it was.
    @Published var notice: MioNotice?

    private func announce(_ notice: MioNotice) {
        self.notice = notice
        let token = notice.id
        Task {
            try? await Task.sleep(for: .seconds(notice.isFailure ? 6 : 2.5))
            // Only clear the one that was announced: a later action that has
            // already replaced it must not be cut short by this one's timer.
            if self.notice?.id == token { self.notice = nil }
        }
    }

    private let institution: Institution
    private let service: MioService
    private var inFlight: Set<String> = []

    init(institution: Institution, websiteDataStore: WKWebsiteDataStore) {
        self.institution = institution
        self.selectedFolderKey = institution.conventions.mio.inboxFolderKey
        service = MioService(institution: institution, websiteDataStore: websiteDataStore)
    }

    // MARK: - What the tab shows

    /// Unread mail, for the badge.
    ///
    /// Taken from the folder count MIO prints when it has one, and counted off
    /// the list itself otherwise — a folder whose menu entry has no bracket is
    /// not necessarily an empty one.
    /// Unread mail, for the badge.
    ///
    /// The **list** is asked first, and the folder count only when there is no
    /// list yet. It used to be the other way round, which is why the badge
    /// could sit on 1 over an inbox with nothing unread in it: the count in
    /// MIO's menu is read once, when the folders are, and pulling the list down
    /// to refresh it re-read the messages without re-reading the menu. The
    /// messages then said "all read" while the menu still said "one waiting",
    /// and the menu was winning.
    var unreadCount: Int {
        let inboxKey = overview.value?.folders.first { $0.kind == .inbox }?.key
            ?? institution.conventions.mio.inboxFolderKey
        if let list = lists[inboxKey]?.value {
            return list.messages.filter { isUnread($0) }.count
        }
        if let counted = overview.value?.folders.first(where: { $0.kind == .inbox })?.unreadCount {
            return max(0, counted - locallyRead.count)
        }
        return 0
    }

    var folders: [MioFolder] {
        overview.value?.folders ?? []
    }

    /// The signed-in cookie jar, for the one view that has to fetch something
    /// itself: a message body with a picture pasted into it.
    var websiteDataStore: WKWebsiteDataStore {
        service.websiteDataStore
    }

    var selectedFolder: MioFolder? {
        folders.first { $0.key == selectedFolderKey }
    }

    /// The list on screen, after the search field has had its say.
    var visibleMessages: [MioMessage] {
        guard let list = lists[selectedFolderKey]?.value else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list.messages }
        return list.messages.filter { $0.matches(trimmed) }
    }

    var currentList: MioLoadable<MioMessageList> {
        lists[selectedFolderKey] ?? .idle
    }

    /// Whether this message still counts as unread, allowing for the ones
    /// opened since the list was fetched.
    func isUnread(_ message: MioMessage) -> Bool {
        message.isUnread && !locallyRead.contains(message.id)
    }

    // MARK: - Loading

    /// Called once the rest of the app has settled. Cheap when already loaded.
    func loadIfNeeded() {
        if case .idle = overview {
            reload()
        }
    }

    /// Whether this store is showing fixtures rather than a mailbox.
    ///
    /// Set once by `HomeView` when the demo account signs in. Every read below
    /// checks it before reaching for the network: the demo has no session, so
    /// a fetch would not fail gracefully, it would fail *visibly*, and a tour
    /// that shows two working tabs and two broken ones is worse than no tour.
    private(set) var isDemo = false

    /// Fills the mailbox with the demo's own mail.
    func loadDemoFixtures() {
        guard !isDemo else { return }
        isDemo = true
        let fetchedAt = Date()
        overview = .loaded(DemoFixtures.mioOverview(fetchedAt: fetchedAt))
        selectedFolderKey = "demo-inbox"
        for folder in folders {
            lists[folder.key] = .loaded(DemoFixtures.mioMessages(in: folder.key))
        }
    }

    func reload() {
        guard !isDemo else { return }
        guard !inFlight.contains("overview") else { return }
        inFlight.insert("overview")
        overview = .loading

        Task {
            defer { inFlight.remove("overview") }
            do {
                let fetched = try await service.fetchOverview()
                overview = .loaded(fetched)
                // Open on the inbox, or on whatever MIO listed first if this
                // college does not have one by that name.
                if !fetched.folders.contains(where: { $0.key == selectedFolderKey }),
                   let first = fetched.inbox {
                    selectedFolderKey = first.key
                }
                loadMessages(in: selectedFolderKey)
            } catch {
                overview = .failed(Self.message(for: error))
            }
        }
    }

    func loadMessages(in folderKey: String) {
        if case .loaded = lists[folderKey] { return }
        fetchMessages(in: folderKey)
    }

    func reloadMessages(in folderKey: String) {
        lists[folderKey] = nil
        locallyRead.removeAll()
        fetchMessages(in: folderKey)
    }

    /// What pulling the list down does.
    ///
    /// The folder menu is re-read as well as the messages. Refreshing one
    /// without the other is how the counts beside "Inbox" and "Flagged" came
    /// to disagree with the list right beside them.
    func refreshEverything() {
        let folderKey = selectedFolderKey
        lists[folderKey] = nil
        locallyRead.removeAll()
        reload()
    }

    private func fetchMessages(in folderKey: String) {
        guard !isDemo else {
            lists[folderKey] = .loaded(DemoFixtures.mioMessages(in: folderKey))
            return
        }
        let key = "list:" + folderKey
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        lists[folderKey] = .loading

        Task {
            defer { inFlight.remove(key) }
            do {
                lists[folderKey] = .loaded(try await service.fetchMessages(in: folderKey))
            } catch {
                lists[folderKey] = .failed(Self.message(for: error))
            }
        }
    }

    func select(_ folder: MioFolder) {
        selectedFolderKey = folder.key
        query = ""
        loadMessages(in: folder.key)
    }

    // MARK: - One message

    func message(for token: String) -> MioLoadable<MioMessageDetail> {
        messages[token] ?? .idle
    }

    func loadMessage(_ message: MioMessage) {
        let token = message.id
        if isDemo {
            messages[token] = .loaded(DemoFixtures.mioDetail(for: token))
            locallyRead.insert(token)
            return
        }
        if case .loaded = messages[token] { return }
        let key = "message:" + token
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        messages[token] = .loading

        Task {
            defer { inFlight.remove(key) }
            do {
                let detail = try await service.fetchMessage(token: token, in: selectedFolderKey)
                messages[token] = .loaded(detail)
                // MIO marked it read when it served the page. The list in hand
                // still says "new", so it is corrected here rather than left to
                // contradict the message the student is looking at.
                locallyRead.insert(token)
            } catch {
                messages[token] = .failed(Self.message(for: error))
            }
        }
    }

    // MARK: - Attachments

    /// Fetches an attachment so the app's own reader can show it.
    func download(_ attachment: MioAttachment, from message: MioMessage) async throws -> URL {
        try await service.downloadAttachment(
            named: attachment.name,
            token: message.id,
            in: selectedFolderKey
        )
    }

    // MARK: - Flags and follow-ups

    /// Both of MIO's own markers, turned on and off from the list.
    ///
    /// The row changes immediately and is put back if MIO disagrees: a flag is
    /// a two-second round trip, and a control that does nothing for two seconds
    /// gets pressed again.
    func toggleFlag(_ message: MioMessage) {
        setIndicator(message, isFlag: true, to: !message.isFlagged)
    }

    func toggleFollowUp(_ message: MioMessage) {
        setIndicator(message, isFlag: false, to: !message.needsSecondRead)
    }

    private func setIndicator(_ message: MioMessage, isFlag: Bool, to value: Bool) {
        let key = (isFlag ? "flag:" : "follow:") + message.id
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        pendingIndicators.insert(message.id)
        apply(to: message.id) { row in
            isFlag
                ? row.withFlag(value)
                : row.withFollowUp(value)
        }

        Task {
            defer {
                inFlight.remove(key)
                pendingIndicators.remove(message.id)
            }
            do {
                try await service.setIndicator(
                    messageID: message.messageID,
                    in: selectedFolderKey,
                    isFlag: isFlag,
                    to: value
                )
                announce(MioNotice(kind: .success, message: Self.success(isFlag: isFlag, on: value)))
                // The folder counts moved too — "Flagged" has one more or one
                // fewer in it than the menu last said.
                refreshFolders()
            } catch {
                // Put it back, and say so. Saying it worked when it did not is
                // worse than the flicker of it returning, and saying nothing at
                // all is how a flag went missing without anybody noticing.
                apply(to: message.id) { row in
                    isFlag ? row.withFlag(!value) : row.withFollowUp(!value)
                }
                announce(MioNotice(kind: .failure, message: Self.failure(isFlag: isFlag)))
            }
        }
    }

    // MARK: - Throwing one away

    /// Messages on their way out, while MIO catches up.
    @Published private(set) var deleting: Set<String> = []

    /// Whether deleting this message destroys it rather than filing it.
    ///
    /// Everywhere else, MIO's Delete moves mail to the deleted items and it can
    /// be fetched back out. In the deleted items themselves there is nowhere
    /// further for it to go, and the student is told so before they press it
    /// rather than after.
    var deletingIsPermanent: Bool {
        selectedFolder?.kind == .deleted
    }

    /// Takes a message out of the list, and puts it back if MIO disagrees.
    ///
    /// The row goes at once, like a flag does, because a Delete that sits there
    /// for four seconds gets pressed again — and a second press on a message
    /// that is already being deleted is how somebody deletes the one underneath
    /// it. The difference from a flag is that this one is checked rather than
    /// trusted: `MioService.delete` re-reads the folder afterwards and refuses
    /// to call it a success unless the list is exactly one message shorter.
    func delete(_ message: MioMessage) {
        let key = "delete:" + message.id
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        deleting.insert(message.id)

        let folderKey = selectedFolderKey
        let snapshot = removeRow(message.id, from: folderKey)
        let wasPermanent = deletingIsPermanent

        Task {
            defer {
                inFlight.remove(key)
                deleting.remove(message.id)
            }
            do {
                try await service.delete(token: message.id, in: folderKey)
                messages[message.id] = nil
                locallyRead.remove(message.id)
                announce(MioNotice(
                    kind: .success,
                    message: wasPermanent
                        ? Loc.text("Deleted")
                        : Loc.text("Moved to deleted items")
                ))
                // The message left one folder and, usually, arrived in another,
                // so every count in the menu has moved.
                refreshFolders()
            } catch {
                if let snapshot { restoreRow(snapshot, in: folderKey) }
                announce(MioNotice(kind: .failure, message: Self.message(for: error)))
            }
        }
    }

    private func removeRow(_ token: String, from folderKey: String) -> (index: Int, message: MioMessage)? {
        guard case .loaded(var list) = lists[folderKey],
              let index = list.messages.firstIndex(where: { $0.id == token })
        else {
            return nil
        }
        let removed = list.messages.remove(at: index)
        lists[folderKey] = .loaded(list)
        return (index, removed)
    }

    private func restoreRow(_ snapshot: (index: Int, message: MioMessage), in folderKey: String) {
        guard case .loaded(var list) = lists[folderKey] else { return }
        // The list may have been refreshed underneath this, so the old index is
        // a hint rather than a promise.
        guard !list.messages.contains(where: { $0.id == snapshot.message.id }) else { return }
        list.messages.insert(snapshot.message, at: min(snapshot.index, list.messages.count))
        lists[folderKey] = .loaded(list)
    }

    private func apply(to token: String, _ change: (MioMessage) -> MioMessage) {
        guard case .loaded(var list) = lists[selectedFolderKey] else { return }
        guard let index = list.messages.firstIndex(where: { $0.id == token }) else { return }
        list.messages[index] = change(list.messages[index])
        lists[selectedFolderKey] = .loaded(list)
    }

    // MARK: - Writing

    /// A compose session, with its own web view, for one message.
    func composeSession() -> MioComposeSession {
        MioComposeSession(institution: institution, service: service)
    }

    /// Called after a message goes out or a draft is saved.
    ///
    /// Everything is dropped, not just the sent folder. A message leaving
    /// changes the sent list, the drafts list (the auto-saved copy of it is
    /// gone), and the counts in the menu — and a list that is already loaded is
    /// never re-fetched, so anything left behind here stays wrong until the
    /// student pulls it down themselves.
    func messageWasSent() {
        lists.removeAll()
        messages.removeAll()
        locallyRead.removeAll()
        reload()
    }

    // MARK: - Errors

    private static func message(for error: Error) -> String {
        (error as? MioService.Failure)?.message ?? error.localizedDescription
    }

    private static func success(isFlag: Bool, on: Bool) -> String {
        switch (isFlag, on) {
        case (true, true): Loc.text("Flagged")
        case (true, false): Loc.text("Flag removed")
        case (false, true): Loc.text("Marked to read again")
        case (false, false): Loc.text("Read-again mark removed")
        }
    }

    private static func failure(isFlag: Bool) -> String {
        isFlag
            ? Loc.text("The flag could not be saved.")
            : Loc.text("The read-again mark could not be saved.")
    }

    /// Re-reads the folder menu without disturbing the list on screen.
    private func refreshFolders() {
        guard !inFlight.contains("overview") else { return }
        inFlight.insert("overview")
        Task {
            defer { inFlight.remove("overview") }
            if let fetched = try? await service.fetchOverview() {
                overview = .loaded(fetched)
            }
        }
    }
}

/// Something that just happened, and whether it worked.
///
/// Deliberately short-lived and non-blocking. The alternative considered was to
/// put a loading screen over everything until OmniVox answered — which is
/// honest, and makes flagging a message a two-second modal interruption. This
/// way the row changes at once, the app checks, and it says so either way.
struct MioNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case failure
    }

    let id = UUID()
    let kind: Kind
    let message: String

    var isFailure: Bool { kind == .failure }

    var symbol: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }
}

/// Something fetched from MIO, and what is currently true about it.
enum MioLoadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

private extension MioMessage {
    func withFlag(_ value: Bool) -> MioMessage {
        MioMessage(
            id: id, messageID: messageID, isSent: isSent, state: state,
            correspondent: correspondent, correspondentLabel: correspondentLabel,
            name: name, subject: subject, preview: preview, dateText: dateText,
            isFlagged: value, needsSecondRead: needsSecondRead,
            attachmentNote: attachmentNote, attachmentSize: attachmentSize,
            category: category, readReceipt: readReceipt, openURL: openURL
        )
    }

    func withFollowUp(_ value: Bool) -> MioMessage {
        MioMessage(
            id: id, messageID: messageID, isSent: isSent, state: state,
            correspondent: correspondent, correspondentLabel: correspondentLabel,
            name: name, subject: subject, preview: preview, dateText: dateText,
            isFlagged: isFlagged, needsSecondRead: value,
            attachmentNote: attachmentNote, attachmentSize: attachmentSize,
            category: category, readReceipt: readReceipt, openURL: openURL
        )
    }
}
