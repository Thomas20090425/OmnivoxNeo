import CryptoKit
import Foundation

/// A link the portal put inside an event's description.
///
/// Kept as structured data rather than left in the text: a student reading
/// "sign up here" needs the link to be tappable, and the app needs to know
/// where it points before deciding what to do with it.
struct PortalLink: Codable, Hashable, Sendable, Identifiable {
    let title: String
    let url: URL

    var id: String { "\(url.absoluteString)|\(title)" }

    /// True when this points back into some school's OmniVox.
    ///
    /// Those links are only meaningful inside an authenticated portal session,
    /// which the app does not hand out to Safari — so they are recognised here
    /// and shown as not-yet-supported instead of opening to a login wall.
    func isPortalInternal(domainSuffix: String) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let suffix = domainSuffix.lowercased()
        return host == suffix || host.hasSuffix(".\(suffix)")
    }

    /// This link with the parts that change on every page load removed.
    ///
    /// OmniVox stamps a fresh `Ref` timestamp, session id and encrypted `Info`
    /// blob into every link it prints, so the same unchanged assignment comes
    /// back with a different address every single refresh. Comparing raw URLs
    /// therefore reported the whole agenda as changed forever: the badge came
    /// straight back after "Mark All as Read", which is exactly what it looked
    /// like from the outside.
    ///
    /// Only used for comparison. The real URL, timestamp and all, is what the
    /// app actually opens — a stripped one would not work.
    var stableIdentity: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "\(title)|\(url.absoluteString)"
        }
        components.queryItems = components.queryItems?.filter {
            !PortalLink.volatileQueryKeys.contains($0.name.lowercased())
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return "\(title)|\(components.string ?? url.path())"
    }

    /// Query names OmniVox re-mints per request rather than per document.
    private static let volatileQueryKeys: Set<String> = [
        "ref", "sid", "info", "k", "lk", "ts", "t", "rnd", "nonce", "token", "cle"
    ]

    /// What to show when the link text is just the URL again, or empty.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != url.absoluteString {
            return trimmed
        }
        return url.host() ?? url.absoluteString
    }
}

struct PortalCalendarEvent: Identifiable, Codable, Hashable, Sendable {
    enum Category: String, Codable, CaseIterable, Sendable {
        case classMeeting
        case coursework
        case academic
        case community
        case other

        var systemImage: String {
            switch self {
            case .classMeeting: "graduationcap.fill"
            case .coursework: "doc.text.fill"
            case .academic: "building.columns.fill"
            case .community: "person.3.fill"
            case .other: "calendar"
            }
        }
    }

    let institutionID: String
    let category: Category
    let title: String
    let subtitle: String?
    let detail: String?
    let location: String?
    let start: Date
    let end: Date?
    let isAllDay: Bool
    /// Links found in the description, in the order the portal wrote them.
    let links: [PortalLink]
    /// The student group or service that published a community event.
    let community: PortalLink?

    init(
        institutionID: String,
        category: Category,
        title: String,
        subtitle: String?,
        detail: String?,
        location: String?,
        start: Date,
        end: Date?,
        isAllDay: Bool,
        links: [PortalLink] = [],
        community: PortalLink? = nil
    ) {
        self.institutionID = institutionID
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.links = links
        self.community = community
    }

    /// Decoded leniently so a cache written before links existed still loads.
    /// Dropping a student's whole cached agenda to add a field would cost them
    /// a full portal round trip for nothing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        institutionID = try container.decode(String.self, forKey: .institutionID)
        category = try container.decode(Category.self, forKey: .category)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decodeIfPresent(Date.self, forKey: .end)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        links = try container.decodeIfPresent([PortalLink].self, forKey: .links) ?? []
        community = try container.decodeIfPresent(PortalLink.self, forKey: .community)
    }

    var id: String {
        [
            institutionID,
            category.rawValue,
            start.formatted(.iso8601),
            end?.formatted(.iso8601) ?? "",
            title,
            subtitle ?? "",
            location ?? ""
        ].joined(separator: "|")
    }

    /// The key the native-calendar mirror files this event under.
    ///
    /// Deliberately coarser than `id`: a room change or a corrected end time
    /// should update the calendar entry the student already has, not leave the
    /// old one behind and add a second. Anything this key cannot absorb — a
    /// moved date — is caught instead by the sweep that removes entries the
    /// portal no longer lists.
    var calendarSyncKey: String {
        [
            institutionID,
            category.rawValue,
            ISO8601DateFormatter.dayOnly.string(from: start),
            title,
            subtitle ?? ""
        ].joined(separator: "|")
    }

    /// True once the event has finished, relative to `date`.
    func hasPassed(by date: Date) -> Bool {
        (end ?? start) < date
    }

    /// Everything a student would notice changing, as one comparable value.
    ///
    /// Deliberately not `Hashable`'s hash: `Hasher` is seeded randomly per
    /// process, so a stored hash would differ after every relaunch and report
    /// the whole agenda as changed. This is stable across launches and devices.
    ///
    /// Links go in by their *stable* identity for the same reason. A teacher
    /// attaching a second handout is news; the portal minting a new timestamp
    /// into the address of the first one is not, and letting that count meant
    /// every item was permanently unread no matter how often it was read.
    var contentSignature: String {
        let fields = [
            title,
            subtitle ?? "",
            detail ?? "",
            location ?? "",
            ISO8601DateFormatter().string(from: start),
            end.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            isAllDay ? "1" : "0",
            links.map(\.stableIdentity).joined(separator: ","),
            community?.stableIdentity ?? ""
        ]
        return Insecure.SHA1.hash(data: Data(fields.joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension ISO8601DateFormatter {
    /// Dates only, so a sync key does not change when a start time is corrected.
    static let dayOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}

/// Something the portal flagged as new since the student last looked.
///
/// Only the "what's new" cards — new documents, grades and assignments — are
/// carried. The general news feed was removed: it is the college talking to
/// everyone, not the portal telling this student something changed, and it had
/// no business competing with coursework for the same space.
struct PortalUpdate: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case whatsNew
        /// No longer collected. Retained so a cache written while the news feed
        /// still existed decodes instead of being thrown away wholesale.
        case news
    }

    let kind: Kind
    let title: String
    let detail: String?

    var id: String {
        [kind.rawValue, title, detail ?? ""].joined(separator: "|")
    }
}
