import Foundation

struct ScheduleSnapshot: Codable, Sendable {
    static let currentContentVersion = 4

    let refreshedAt: Date
    let courses: [CourseMeeting]
    let events: [PortalCalendarEvent]?
    let updates: [PortalUpdate]?
    let firstName: String?
    let contentVersion: Int?

    init(
        refreshedAt: Date,
        courses: [CourseMeeting],
        events: [PortalCalendarEvent] = [],
        updates: [PortalUpdate] = [],
        firstName: String? = nil
    ) {
        self.refreshedAt = refreshedAt
        self.courses = courses
        self.events = events
        self.updates = updates
        self.firstName = firstName
        contentVersion = Self.currentContentVersion
    }
}

struct ScheduleCache: Sendable {
    let profileID: UUID

    func load() -> ScheduleSnapshot? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(ScheduleSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: ScheduleSnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            let directoryURL = self.directoryURL
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            }
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var protectedDirectoryURL = directoryURL
            try? protectedDirectoryURL.setResourceValues(resourceValues)
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: fileURL, options: .atomic)
            #endif
        } catch {
            // A cache failure should never prevent the live schedule from working.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private var directoryURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appending(path: "OmnivoxNeo/profiles", directoryHint: .isDirectory)
    }

    private var fileURL: URL {
        directoryURL.appending(path: "schedule-\(profileID.uuidString).json")
    }
}
