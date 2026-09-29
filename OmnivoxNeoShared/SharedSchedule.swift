import Foundation

/// One class, reduced to what a widget needs to draw.
///
/// Deliberately not `CourseMeeting`: the widget must keep working when the app
/// changes its own model, and a widget that fails to decode shows the user a
/// blank rectangle on their Home Screen.
public struct SharedCourse: Codable, Hashable, Sendable, Identifiable {
    public let title: String
    public let courseLabel: String?
    public let location: String?
    public let start: Date
    public let end: Date

    public var id: String { "\(start.timeIntervalSince1970)-\(title)" }

    public init(
        title: String,
        courseLabel: String?,
        location: String?,
        start: Date,
        end: Date
    ) {
        self.title = title
        self.courseLabel = courseLabel
        self.location = location
        self.start = start
        self.end = end
    }
}

/// What the app hands to its widgets.
///
/// Written to the shared App Group container after every successful schedule
/// refresh, and read by the widget process, which has no access to the app's
/// own container, Keychain or cookies. Only what is drawn on a Home Screen is
/// shared — never credentials or the authenticator secret.
public struct SharedSchedule: Codable, Sendable {
    public static let appGroupID = "group.com.tjokas.OmnivoxNeo"
    public static let fileName = "widget-schedule.json"

    /// Whose schedule this is. The widget follows the account that used the app
    /// last, because a Home Screen has no way to ask which one you meant.
    public let accountLabel: String
    public let schoolName: String
    /// Raw value of the student's `AccentChoice`, so the widget matches the app.
    public let accentID: String
    public let updatedAt: Date
    public let courses: [SharedCourse]

    public init(
        accountLabel: String,
        schoolName: String,
        accentID: String,
        updatedAt: Date,
        courses: [SharedCourse]
    ) {
        self.accountLabel = accountLabel
        self.schoolName = schoolName
        self.accentID = accentID
        self.updatedAt = updatedAt
        self.courses = courses
    }

    // MARK: - Shared container

    public static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    @discardableResult
    public func write() -> Bool {
        guard let url = Self.fileURL else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func load() -> SharedSchedule? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedSchedule.self, from: data)
    }

    /// Removed when the last account leaves the device, so a widget never keeps
    /// showing the schedule of someone who signed out.
    public static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Queries the widget asks

    public func courses(on day: Date, calendar: Calendar = .current) -> [SharedCourse] {
        courses
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.start < $1.start }
    }

    public func current(at date: Date) -> SharedCourse? {
        courses.first { $0.start <= date && date < $0.end }
    }

    public func next(after date: Date) -> SharedCourse? {
        courses
            .filter { $0.start > date }
            .min { $0.start < $1.start }
    }
}
