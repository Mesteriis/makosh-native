import Foundation

public enum CalendarViewMode: String, Codable, CaseIterable, Sendable {
    case day, week, month
}

/// Section preferences; missing keys take defaults so older rows keep reading.
public struct CalendarPreferences: Codable, Equatable, Sendable {
    public var view: CalendarViewMode = .week
    public var showTasks = true
    public var lastCollectionID: UUID?
    public var horizonDays = 90
    public var pollSeconds = 120
    public var subscriptionPollSeconds = 3600
    public var defaultReminderMinutes = 10
    public var maxWritesPerPass = 50
    /// `Calendar.firstWeekday`: 2 = Monday.
    public var firstWeekday = 2

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case view, showTasks, lastCollectionID, horizonDays, pollSeconds, subscriptionPollSeconds, defaultReminderMinutes, maxWritesPerPass,
            firstWeekday
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CalendarPreferences()
        view = (try? c.decodeIfPresent(CalendarViewMode.self, forKey: .view)) ?? defaults.view
        showTasks = (try? c.decodeIfPresent(Bool.self, forKey: .showTasks)) ?? defaults.showTasks
        lastCollectionID = try? c.decodeIfPresent(UUID.self, forKey: .lastCollectionID)
        horizonDays = (try? c.decodeIfPresent(Int.self, forKey: .horizonDays)) ?? defaults.horizonDays
        pollSeconds = (try? c.decodeIfPresent(Int.self, forKey: .pollSeconds)) ?? defaults.pollSeconds
        subscriptionPollSeconds = (try? c.decodeIfPresent(Int.self, forKey: .subscriptionPollSeconds)) ?? defaults.subscriptionPollSeconds
        defaultReminderMinutes = (try? c.decodeIfPresent(Int.self, forKey: .defaultReminderMinutes)) ?? defaults.defaultReminderMinutes
        maxWritesPerPass = (try? c.decodeIfPresent(Int.self, forKey: .maxWritesPerPass)) ?? defaults.maxWritesPerPass
        firstWeekday = (try? c.decodeIfPresent(Int.self, forKey: .firstWeekday)) ?? defaults.firstWeekday
    }
}

extension CalendarStore {
    public func preferences() throws -> CalendarPreferences {
        try query("SELECT data FROM \(t("calendar_preferences")) WHERE id = 1").first.map { try decode(CalendarPreferences.self, $0[0]) }
            ?? CalendarPreferences()
    }

    public func savePreferences(_ value: CalendarPreferences) throws {
        try execute(
            "INSERT INTO \(t("calendar_preferences"))(id, data) VALUES (1, $1::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data",
            [try encode(value)])
    }
}
