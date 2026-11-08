import Foundation

/// A reminder Makosh shows itself, keyed so that a moved event gets a new one.
public struct CalendarReminder: Hashable, Sendable {
    /// `<eventID>.<occurrence key epoch>.<minutes>`.
    public let identifier: String
    public let eventID: UUID
    public let fireAt: Date
    public let title: String
    public let start: Date
}

public enum CalendarReminderPlanner {
    /// Reminders due within `lookahead` for originals not declined; busy copies never remind.
    /// Minutes come from the event, else from its calendar's default.
    public static func reminders(snapshot: CalendarSnapshot, now: Date, lookahead: TimeInterval = 86400) -> Set<CalendarReminder> {
        let defaults = Dictionary(uniqueKeysWithValues: snapshot.collections.map { ($0.id, $0.defaultReminderMinutes) })
        var result = Set<CalendarReminder>()
        for occurrence in snapshot.occurrences {
            guard let event = snapshot.events[occurrence.eventID], !event.isBusyCopy, event.deletedAt == nil, event.status != .cancelled,
                event.selfResponse != .declined
            else { continue }
            let minutes = event.reminders.isEmpty ? [defaults[occurrence.collectionID] ?? 10] : event.reminders
            for minute in Set(minutes) where minute >= 0 {
                let fireAt = occurrence.start.addingTimeInterval(TimeInterval(-minute * 60))
                guard fireAt > now, fireAt <= now.addingTimeInterval(lookahead) else { continue }
                result.insert(
                    CalendarReminder(
                        identifier: "\(event.id.uuidString).\(Int(occurrence.start.timeIntervalSince1970)).\(minute)", eventID: event.id,
                        fireAt: fireAt, title: event.title, start: occurrence.start))
            }
        }
        return result
    }

    /// The event a reminder identifier points to; anything malformed is nil.
    public static func eventID(fromIdentifier identifier: String) -> UUID? {
        let parts = identifier.split(separator: ".")
        guard parts.count == 3, Int(parts[1]) != nil, Int(parts[2]) != nil else { return nil }
        return UUID(uuidString: String(parts[0]))
    }
}
