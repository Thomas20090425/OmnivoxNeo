import Combine
import Foundation

/// What has changed in the agenda since the student last looked.
///
/// Every refresh leaves behind a fingerprint of what the portal said — one
/// stable key per event, mapped to a signature of its contents. The next
/// refresh compares against it, so "new" and "changed" are answered by
/// evidence rather than by guessing from dates. A deadline moved a week
/// earlier is not a new event and would never show up as one under a
/// "what's happening soon" heuristic; here it does.
///
/// The record that matters is `acknowledged`: what the student has actually
/// seen. Reading used to be recorded by *absence* — an event was read if it was
/// missing from `unread`, measured against whatever the last scrape happened to
/// say. That made "Mark All as Read" only as durable as the portal was
/// repetitive: any wobble in what came back put every item straight back, and
/// no amount of tapping could clear it. Acknowledgement is now written down
/// positively, so an item stays read until its contents change *from the
/// version that was read*.
///
/// Scoped to the profile: two students sharing a device each have their own
/// idea of what they have already seen.
@MainActor
final class AgendaReadState: ObservableObject {
    /// Bumped when the meaning of what is stored changes. A mismatch
    /// re-baselines rather than migrating: the cost is one silent refresh,
    /// against an upgrade that would otherwise announce the entire agenda as
    /// new — which is the exact complaint this type exists to answer.
    /// 3: signatures stopped counting the per-request timestamp OmniVox stamps
    /// into every link, which had made every item unread on every refresh.
    /// Records written before that compare against a different signature, so
    /// they re-baseline once rather than announcing the term all over again.
    private static let storageVersion = 3

    private let profileID: UUID
    private let defaults: UserDefaults

    /// Event key → the signature of the version the student has seen.
    private var acknowledged: [String: String]
    /// Event key → its current signature, for everything not yet acknowledged.
    ///
    /// Carrying the signature here is what lets a single day be marked read
    /// without going back to the portal for it.
    private var pending: [String: String]
    /// Whether a baseline has ever been taken.
    private var hasBaseline: Bool
    /// The language the baseline was scraped in.
    ///
    /// Event identity is built from the portal's own words, so the same class
    /// has a different key in French than in English. Without this, switching
    /// language re-read the portal, found no key it recognised, and reported
    /// the entire agenda as new.
    private var language: String?

    init(profileID: UUID, defaults: UserDefaults = .standard) {
        self.profileID = profileID
        self.defaults = defaults

        let storedVersion = defaults.integer(forKey: Self.key("version", profileID))
        guard storedVersion == Self.storageVersion else {
            acknowledged = [:]
            pending = [:]
            hasBaseline = false
            language = nil
            return
        }

        acknowledged = Self.decode(defaults.data(forKey: Self.key("acknowledged", profileID))) ?? [:]
        pending = Self.decode(defaults.data(forKey: Self.key("pending", profileID))) ?? [:]
        hasBaseline = defaults.bool(forKey: Self.key("baseline", profileID))
        language = defaults.string(forKey: Self.key("language", profileID))
    }

    // MARK: - Reading the difference

    /// Folds a freshly scraped agenda into what was already known.
    ///
    /// Called only after a real refresh, never when the cache is loaded at
    /// launch — reloading yesterday's cache is not the portal saying anything
    /// new, and treating it as such would clear or inflate the count on every
    /// cold start.
    ///
    /// `treatingFirstSightAsNew` is for the demo fixtures, which have no history
    /// to compare against and exist precisely to show what unread looks like.
    func reconcile(
        with events: [PortalCalendarEvent],
        language: String,
        treatingFirstSightAsNew: Bool = false
    ) {
        let current = Self.signatures(of: events)

        // The first sight of an account is the baseline, not a hundred unread
        // items. Somebody signing in for the first time has not missed
        // anything — they have not had the chance to.
        guard hasBaseline || treatingFirstSightAsNew else {
            objectWillChange.send()
            acknowledged = current
            pending = [:]
            hasBaseline = true
            self.language = language
            persist()
            return
        }

        // A language switch rewrites every title the portal sends, and titles
        // are part of an event's identity — so nothing would match and the
        // whole agenda would look new. That is a translation, not news.
        // Re-baseline against the new language instead, keeping unread only the
        // items that were already unread and whose identity survived the change.
        //
        // A nil stored language is an install that predates this field; it is
        // treated as a match so the update itself does not light up the badge.
        if let previous = self.language, previous != language {
            objectWillChange.send()
            let survivors = pending.filter { current.keys.contains($0.key) }
            acknowledged = current.filter { !survivors.keys.contains($0.key) }
            pending = survivors
            self.language = language
            persist()
            return
        }

        var updatedPending: [String: String] = [:]
        for (key, signature) in current where acknowledged[key] != signature {
            updatedPending[key] = signature
        }

        // An event the portal has stopped listing cannot be read, so it stops
        // being counted rather than pinning the badge on forever. Its
        // acknowledgement goes with it, which also keeps the store from growing
        // for the length of a degree.
        let prunedAcknowledged = acknowledged.filter { current.keys.contains($0.key) }

        guard updatedPending != pending
            || prunedAcknowledged != acknowledged
            || !hasBaseline
            || self.language != language
        else { return }

        objectWillChange.send()
        pending = updatedPending
        acknowledged = prunedAcknowledged
        hasBaseline = true
        self.language = language
        persist()
    }

    // MARK: - Queries

    var unreadCount: Int { pending.count }
    var hasUnread: Bool { !pending.isEmpty }

    func isUnread(_ event: PortalCalendarEvent) -> Bool {
        pending[Self.identity(of: event)] != nil
    }

    func unreadCount(among events: [PortalCalendarEvent]) -> Int {
        events.reduce(into: 0) { total, event in
            if pending[Self.identity(of: event)] != nil { total += 1 }
        }
    }

    // MARK: - Acknowledging

    /// Marks everything currently unread as seen.
    func markAllRead() {
        guard !pending.isEmpty else { return }
        objectWillChange.send()
        acknowledged.merge(pending) { _, seen in seen }
        pending = [:]
        persist()
    }

    /// Marks just these events as seen — one day's worth, as the student moves
    /// through the calendar.
    ///
    /// Days nobody opened keep their badge, which is the only thing that makes
    /// a per-day badge worth drawing.
    func markRead(_ events: [PortalCalendarEvent]) {
        var acknowledgedAny = false
        for event in events {
            let key = Self.identity(of: event)
            guard let signature = pending[key] else { continue }
            acknowledged[key] = signature
            pending[key] = nil
            acknowledgedAny = true
        }
        guard acknowledgedAny else { return }
        objectWillChange.send()
        persist()
    }

    /// Everything this account knows about what it has seen.
    func clear() {
        objectWillChange.send()
        acknowledged = [:]
        pending = [:]
        hasBaseline = false
        language = nil
        for name in ["acknowledged", "pending", "baseline", "language", "version"] {
            defaults.removeObject(forKey: Self.key(name, profileID))
        }
    }

    // MARK: - Storage

    private func persist() {
        defaults.set(try? JSONEncoder().encode(acknowledged), forKey: Self.key("acknowledged", profileID))
        defaults.set(try? JSONEncoder().encode(pending), forKey: Self.key("pending", profileID))
        defaults.set(hasBaseline, forKey: Self.key("baseline", profileID))
        defaults.set(language, forKey: Self.key("language", profileID))
        defaults.set(Self.storageVersion, forKey: Self.key("version", profileID))
    }

    /// The agenda's own events, keyed by full identity.
    ///
    /// `id` rather than `calendarSyncKey`: the sync key is deliberately coarse
    /// so the native-calendar mirror can update an entry in place, which means
    /// two items on the same day under the same title collapse into one. That
    /// is right for a calendar and wrong for a badge — whichever of the two was
    /// scraped last would silently decide what the other one counted as.
    private static func signatures(of events: [PortalCalendarEvent]) -> [String: String] {
        Dictionary(
            events.filter { $0.category.belongsInAgenda }
                .map { (identity(of: $0), $0.contentSignature) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private static func identity(of event: PortalCalendarEvent) -> String { event.id }

    private static func decode(_ data: Data?) -> [String: String]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func key(_ name: String, _ profileID: UUID) -> String {
        "agenda.\(name).\(profileID.uuidString)"
    }
}
