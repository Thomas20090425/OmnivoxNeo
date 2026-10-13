import Foundation

/// What the manifest says about one build.
///
/// Decoded leniently on purpose. This file is hand-edited, lives outside the
/// app, and is the only thing that can lock a student out of their own
/// timetable — so every way of getting it wrong has to land on `normal`. An
/// unknown status, a missing entry, a malformed file and an unreachable server
/// all mean the same thing: let them in.
enum VersionStatus: String, Decodable, Sendable {
    case normal
    case updateRecommended
    case updateRequired

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Matched loosely because the value is typed by a person: a stray
        // capital or a trailing space must not read as "something is wrong".
        let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch folded {
        case "updaterecommended", "update_recommended", "recommended":
            self = .updateRecommended
        case "updaterequired", "update_required", "required":
            self = .updateRequired
        default:
            self = .normal
        }
    }
}

struct VersionEntry: Decodable, Sendable {
    var status: VersionStatus = .normal
    var announcement: String?
    var announcementTitle: String?

    private enum CodingKeys: String, CodingKey {
        case status = "Status"
        case announcement = "Announcement"
        case announcementTitle = "AnnouncementTitle"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? container.decode(VersionStatus.self, forKey: .status)) ?? .normal
        announcement = Self.cleaned(try? container.decode(String.self, forKey: .announcement))
        announcementTitle = Self.cleaned(
            try? container.decode(String.self, forKey: .announcementTitle)
        )
    }

    init(status: VersionStatus, announcement: String? = nil, announcementTitle: String? = nil) {
        self.status = status
        self.announcement = Self.cleaned(announcement)
        self.announcementTitle = Self.cleaned(announcementTitle)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

struct VersionManifest: Decodable, Sendable {
    /// The only shape this app knows how to read.
    static let supportedSchema = 1

    var schemaVersion: Int = 0
    var appStoreURL: URL?
    var testFlightURL: URL?
    var terminatesAfterUpdateRedirect: Bool = false
    var versions: [String: VersionEntry] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "SchemaVersion"
        case appStoreURL = "AppStoreURL"
        case testFlightURL = "TestFlightURL"
        case terminatesAfterUpdateRedirect = "TerminateAfterUpdateRedirect"
        case versions = "Versions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        appStoreURL = Self.url(try? container.decode(String.self, forKey: .appStoreURL))
        testFlightURL = Self.url(try? container.decode(String.self, forKey: .testFlightURL))
        terminatesAfterUpdateRedirect =
            (try? container.decode(Bool.self, forKey: .terminatesAfterUpdateRedirect)) ?? false
        // A single unreadable entry must not cost us the rest of the file, so
        // the map is decoded one value at a time rather than wholesale.
        if let raw = try? container.decode([String: VersionEntry].self, forKey: .versions) {
            versions = raw
        }
    }

    init(
        schemaVersion: Int = VersionManifest.supportedSchema,
        appStoreURL: URL? = nil,
        testFlightURL: URL? = nil,
        terminatesAfterUpdateRedirect: Bool = false,
        versions: [String: VersionEntry] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.appStoreURL = appStoreURL
        self.testFlightURL = testFlightURL
        self.terminatesAfterUpdateRedirect = terminatesAfterUpdateRedirect
        self.versions = versions
    }

    /// Only an absolute `https` address counts. A relative string, a `http://`
    /// address or a `javascript:` anything is a mistake in the file, and the
    /// button is better missing than pointed somewhere unexpected.
    private static func url(_ value: String?) -> URL? {
        guard
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// The entry for a build, matched exactly once whitespace is set aside.
    ///
    /// Deliberately not a range or a comparison: "anything older than this"
    /// sounds convenient until a hotfix needs to be exempted, and an exact
    /// table is the version of this that can be read and trusted at a glance.
    func entry(for version: String) -> VersionEntry? {
        let wanted = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let direct = versions[wanted] { return direct }
        return versions.first { key, _ in
            key.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }?.value
    }

    /// Where this build's "Update" button should go.
    func updateDestination(for channel: AppRelease.Channel) -> URL? {
        switch channel {
        case .alpha:
            return appStoreURL
        // Internal builds are handed out through TestFlight too, so they get
        // the same door. Nobody holding one has an App Store listing to go to.
        case .beta, .internalBuild:
            return testFlightURL ?? appStoreURL
        }
    }
}

/// What the app should actually do, once the manifest and the build are both
/// known. Separated from the manifest so the decision can be tested without a
/// network, a bundle, or a running app.
enum VersionGateDecision: Equatable, Sendable {
    /// Carry on, and say nothing.
    case proceed
    /// Carry on, but show this first. One OK, then out of the way.
    case announce(title: String, message: String)
    /// Carry on, but ask them to update on the way past.
    case recommendUpdate(message: String, destination: URL?)
    /// Stop here.
    case requireUpdate(message: String, destination: URL?, terminates: Bool)

    /// Whether the app underneath may run at all.
    var allowsApp: Bool {
        if case .requireUpdate = self { return false }
        return true
    }

    /// The sentence the app writes itself for a required update.
    ///
    /// Fixed, and not read from the manifest, because it is the one line that
    /// has to be right every time. Whatever the manifest adds is appended
    /// after it, so an editor only ever writes the build-specific part.
    static let requiredUpdatePreamble =
        "A critical fix is available. Please update to the newest version."

    static func make(
        manifest: VersionManifest?,
        version: String,
        channel: AppRelease.Channel
    ) -> VersionGateDecision {
        // No manifest yet, or one written against a shape we do not know.
        guard
            let manifest,
            manifest.schemaVersion == VersionManifest.supportedSchema,
            let entry = manifest.entry(for: version)
        else { return .proceed }

        let destination = manifest.updateDestination(for: channel)

        switch entry.status {
        case .normal:
            guard let announcement = entry.announcement else { return .proceed }
            return .announce(
                title: entry.announcementTitle ?? "One Thing To Know",
                message: announcement
            )

        case .updateRecommended:
            return .recommendUpdate(
                message: entry.announcement ?? "A newer version of Omnivox Neo is available.",
                destination: destination
            )

        case .updateRequired:
            // Preamble first, the specific part after it, one space between.
            let message = [requiredUpdatePreamble, entry.announcement]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            return .requireUpdate(
                message: message,
                destination: destination,
                terminates: manifest.terminatesAfterUpdateRedirect
            )
        }
    }
}
