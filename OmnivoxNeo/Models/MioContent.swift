import Foundation

/// Everything MIO — OmniVox's internal messaging — publishes.
///
/// MIO is a separate module again from both the portal and Léa: its own host
/// path, its own session, and a real 1990s frameset around the parts that
/// matter. The shapes here stay close to what its pages actually say, for the
/// same reason the Léa models do: a date is the string MIO printed, because
/// "09:28" and "2026-09-25" are the same field and mean "today" and "a while
/// ago", and normalising them throws that away.
///
/// What is *not* kept verbatim is anything MIO says in words that differ by
/// language. Whether a message is unread, sent, replied to, or from a teacher
/// is read from the icon file MIO draws, never from the label under it.

// MARK: - Folders

/// One entry in MIO's left-hand menu.
struct MioFolder: Identifiable, Hashable, Sendable {
    /// What this folder is, independent of what it is called.
    ///
    /// Taken from the `SEARCH_FOLDER_…` token in the address, which is the same
    /// in every language, rather than from the printed name, which is not.
    /// `.custom` is a folder the student made themselves.
    enum Kind: String, Hashable, Sendable, Codable {
        case inbox
        case sent
        case drafts
        case flagged
        case categorised
        case deleted
        case custom
    }

    /// MIO's own token for this folder — what goes in the address.
    let key: String
    let kind: Kind
    /// MIO's label, already in the student's language.
    let name: String
    /// The count MIO prints in brackets, when it prints one.
    let unreadCount: Int?

    var id: String { key }

    /// The symbol this folder is drawn with.
    var symbol: String {
        switch kind {
        case .inbox: "tray.fill"
        case .sent: "paperplane.fill"
        case .drafts: "doc.text"
        case .flagged: "flag.fill"
        case .categorised: "folder.fill"
        case .deleted: "trash.fill"
        case .custom: "folder"
        }
    }
}

// MARK: - Messages

/// One row in a message list.
struct MioMessage: Identifiable, Hashable, Sendable {
    /// What MIO's state icon says has happened to this message.
    ///
    /// Read from the icon's own file name — `mio_MessageNonLu.svg` and friends
    /// — which does not change with the interface language, unlike the `<title>`
    /// underneath it that says "New message" or "Nouveau message".
    enum State: String, Hashable, Sendable, Codable {
        case unread
        case read
        case replied
        case sent
        case unknown
    }

    /// Who the other person is, by the badge MIO draws beside them.
    enum Correspondent: String, Hashable, Sendable, Codable {
        case student
        case employee
        case manager
        case unknown

        var symbol: String {
            switch self {
            case .student: "graduationcap.fill"
            case .employee: "person.fill"
            case .manager: "briefcase.fill"
            case .unknown: "person.fill"
            }
        }
    }

    /// The token MIO uses to address this message — its id with the
    /// sent/received flag stuck on the end, exactly as MIO writes it.
    let id: String
    /// The bare identifier, which is what the flag and follow-up endpoints want.
    let messageID: String
    let isSent: Bool
    let state: State
    let correspondent: Correspondent
    /// MIO's own word for the correspondent — "Employee", "Manager" — kept for
    /// reading aloud, because the symbol alone says nothing to a screen reader.
    let correspondentLabel: String?
    /// The sender, or in a sent folder the recipient.
    let name: String
    let subject: String
    /// The first line or so of the body, as MIO previews it.
    let preview: String
    /// "09:28" for today, "2026-09-25" for anything older. MIO's own choice.
    let dateText: String
    let isFlagged: Bool
    /// MIO's "to read again" marker — the student's own reminder.
    let needsSecondRead: Bool
    /// "1 attached file", verbatim, or nil when there are none.
    let attachmentNote: String?
    /// "416 Kb", verbatim.
    let attachmentSize: String?
    let category: String?
    /// How many recipients have opened it. Sent messages only.
    let readReceipt: MioReadReceipt?
    /// Where MIO itself sends you when you press this row.
    ///
    /// Only used where the reader is the wrong screen — a draft opens in the
    /// editor, and MIO's own link is the only thing that knows that address.
    let openURL: URL?

    var isUnread: Bool { state == .unread }
    var hasAttachments: Bool { attachmentNote != nil }

    /// What a search matches against.
    ///
    /// MIO's own search is a round trip to the server and a page reload; this
    /// is what makes typing feel instant while that is happening. It matches
    /// the same four things MIO does — sender, recipients, subject, body — as
    /// far as the list actually carries them.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = [name, subject, preview, category]
            .compactMap { $0 }
            .joined(separator: " ")
        return haystack.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}

/// "1/1" — how many of the people a message went to have opened it.
///
/// MIO shows this only on things the student sent, and it is the one piece of
/// information here that has no equivalent in an email client: it is the answer
/// to "did my teacher actually see it".
struct MioReadReceipt: Hashable, Sendable, Codable {
    let read: Int
    let total: Int

    var isComplete: Bool { total > 0 && read >= total }
    var text: String { "\(read)/\(total)" }
}

/// One fetch of one folder.
struct MioMessageList: Hashable, Sendable {
    var folderKey: String
    var messages: [MioMessage]
    /// "28 messages", verbatim, which is also MIO's way of saying "and no more".
    var totalText: String?
}

// MARK: - One message

struct MioMessageDetail: Hashable, Sendable {
    let subject: String
    let sender: String?
    /// Everyone it went to, as MIO lists them.
    let recipients: [String]
    let dateText: String?
    /// The body as MIO wrote it, HTML and all — teachers use lists, bold and
    /// links, and flattening it loses what they meant by them.
    let bodyHTML: String
    /// The page this was read from.
    ///
    /// Kept because a picture pasted into the middle of a message is stored as
    /// `<img src="ReadImageAttachement.ashx?Info=…">` — an address relative to
    /// that page and behind the signed-in session. Without somewhere to resolve
    /// it against, the picture is addressed to nowhere and the message arrives
    /// with a hole in it.
    let baseURL: URL?
    let attachments: [MioAttachment]
    let readReceipt: MioReadReceipt?
    /// Whether MIO offers a reply — it does not on everything.
    let canReply: Bool
    let canReplyAll: Bool
}

struct MioAttachment: Identifiable, Hashable, Sendable {
    let name: String
    let sizeText: String?
    let url: URL

    var id: String { url.absoluteString + name }
}

// MARK: - Writing one

/// What the student is composing, before MIO has seen any of it.
///
/// Held here rather than in the web page so the screen can be native: MIO's own
/// editor is a Telerik rich-text control inside an iframe inside a frameset,
/// and typing into it through injected JavaScript is neither pleasant nor
/// reliable. The text goes into MIO's form only when Send is pressed.
struct MioDraft: Hashable, Sendable {
    /// What this message is: a new one, or MIO's own reply/forward of another.
    ///
    /// It matters because MIO fills the recipients in itself for the last
    /// three, which is the whole reason replying can be native while writing to
    /// somebody new needs MIO's own picker.
    enum Intent: Hashable, Sendable {
        case new
        case reply(to: String)
        case replyAll(to: String)
        case forward(of: String)
        /// A draft, reopened for editing.
        ///
        /// MIO's own Edit link is `NouveauMessage.ashx?IdMessage=…&Action=Draft`
        /// — the same compose page as everything else, with an action of its
        /// own. Following the row's link instead opened the *reader*, which is
        /// why a draft could be looked at and never finished.
        case draft(of: String)

        /// MIO's own name for the action, for the address it opens.
        var action: String? {
            switch self {
            case .new: nil
            case .draft: "Draft"
            case .reply: "Reply"
            case .replyAll: "ReplyAll"
            case .forward: "Forward"
            }
        }

        var messageID: String? {
            switch self {
            case .new: nil
            case .reply(let id), .replyAll(let id), .forward(let id), .draft(let id): id
            }
        }
    }

    var intent: Intent = .new
    var subject: String = ""
    var body: String = ""
    /// Who MIO says it is going to, once its own form has been opened.
    var recipients: [String] = []
    /// MIO's checkbox for hiding the recipient list from the recipients.
    var hidesRecipients: Bool = false

    var isSendable: Bool {
        !recipients.isEmpty && !(subject.isEmpty && body.isEmpty)
    }

    var hasContent: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A file already attached to the message being written.
struct MioComposeAttachment: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let sizeText: String
    /// MIO's own control for taking it off again, when it offers one.
    let removeID: String?
}

// MARK: - Choosing who it goes to

/// One screen of MIO's recipient picker, read into something native.
///
/// The picker is three screens behind one address: a menu of ways to find
/// somebody, a browser of the student's own classes, and a search across the
/// whole college. Which one is showing is told from which container is on the
/// page — the headings are translated, the class names are not.
///
/// Every actionable thing carries an `id` that is a handle back to the node it
/// came from, so tapping a name here presses the same thing MIO would have had
/// the student press. None of it is re-implemented: the college's rules about
/// who may write to whom stay where they are, on MIO's side.
struct MioPickerPage: Hashable, Sendable {
    enum Mode: String, Hashable, Sendable, Codable {
        /// The menu: "I wish to add…".
        case chooser
        /// The student's own classes, expandable.
        case groups
        /// A search by name across the college.
        case search
        /// Something this app has not been shown. Falls back to MIO's own page
        /// rather than to a blank screen.
        case unknown
    }

    /// One way in, from the chooser.
    struct Option: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        /// The little heading above it, when MIO printed one.
        let group: String
    }

    /// One person who can be added.
    struct Person: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let detail: String
        /// The heading MIO filed them under — "Employees", "Teachers",
        /// "Students". Its own words, so it is shown rather than re-derived,
        /// and it is what the results are grouped and filtered by.
        let section: String
        let correspondent: MioMessage.Correspondent
    }

    /// One class, with its people folded away until asked for.
    struct Group: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let subtitle: String
        let isExpanded: Bool
        let expandID: String?
        /// "Add all the students in this class", when MIO offers it.
        let addAllID: String?
        let addAllTitle: String
        let members: [Person]
        let emptyNote: String
    }

    /// A term or campus menu above the class list.
    struct Filter: Identifiable, Hashable, Sendable {
        struct Choice: Identifiable, Hashable, Sendable {
            let id: String
            let title: String
        }

        let id: String
        let label: String
        let selection: String
        let choices: [Choice]
    }

    /// Somebody already chosen. Pressing them again takes them off the list,
    /// which is MIO's own behaviour rather than this app's invention.
    struct Chosen: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let section: String
    }

    var mode: Mode = .unknown
    var title: String = ""
    var instructions: String = ""
    var options: [Option] = []
    var groups: [Group] = []
    var filters: [Filter] = []
    var results: [Person] = []
    var searchLabel: String = ""
    var searchText: String = ""
    var hasSearched = false
    var emptyNote: String = ""
    var overflowNote: String = ""
    var chosen: [Chosen] = []
    /// "You can send a Mio to a maximum of 75 recipients" — MIO's own number.
    var warning: String = ""
    var isBusy = false
    /// Whether MIO's own "save this selection" control was found.
    var canCommit = false
    /// Whether MIO offers a way back to the menu from here.
    var canGoBack = false

    /// Whether this app can draw this screen itself.
    var isNative: Bool { mode != .unknown }
}

// MARK: - The whole module

/// One fetch of MIO's own chrome: which folders exist and what is in them.
struct MioOverview: Hashable, Sendable {
    var folders: [MioFolder]
    var fetchedAt: Date

    static let empty = MioOverview(folders: [], fetchedAt: .distantPast)

    var inbox: MioFolder? {
        folders.first { $0.kind == .inbox } ?? folders.first
    }

    /// What goes on the tab's badge.
    var unreadCount: Int {
        folders.first { $0.kind == .inbox }?.unreadCount ?? 0
    }
}

/// So a sheet can be driven by "what is being written".
extension MioDraft.Intent: Identifiable {
    var id: String {
        switch self {
        case .new: "new"
        case .reply(let message): "reply:" + message
        case .replyAll(let message): "replyAll:" + message
        case .forward(let message): "forward:" + message
        case .draft(let message): "draft:" + message
        }
    }
}
