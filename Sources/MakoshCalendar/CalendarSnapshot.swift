import Foundation

/// Everything the section shows at once; value copies cross to the main actor.
public struct CalendarSnapshot: Sendable {
    public var accounts: [CalendarAccount]
    public var collections: [CalendarCollection]
    public var groups: [CalendarGroup]
    public var occurrences: [CalendarOccurrence]
    public var events: [UUID: CalendarEvent]
    public var openAttempts: [CalendarAttempt]
    /// Originals overlapping other busy time in their groups, found after the fact.
    public var externalConflicts: [CalendarConflict]
    /// Calendars whose account cannot be read now: their busy copies may be stale.
    public var staleCollectionIDs: Set<UUID>
    public var window: DateInterval
    public var googleAvailable: Bool
    public var preferences: CalendarPreferences
}

enum CalendarExpansion {
    /// Expands masters with their overrides; copies and orphan overrides stand alone.
    static func occurrences(_ events: [CalendarEvent], in window: DateInterval) -> [CalendarOccurrence] {
        var overrides: [String: [CalendarEvent]] = [:]
        for event in events where event.recurrenceID != nil {
            overrides[event.collectionID.uuidString + "/" + event.uid, default: []].append(event)
        }
        var masters = Set<String>()
        var result: [CalendarOccurrence] = []
        for event in events where event.recurrenceID == nil {
            let key = event.collectionID.uuidString + "/" + event.uid
            if event.recurrence != nil { masters.insert(key) }
            result += CalendarRecurrenceExpander.occurrences(
                of: event, overrides: event.recurrence == nil ? [] : overrides[key] ?? [], in: window)
        }
        for (key, list) in overrides where !masters.contains(key) {
            for event in list where event.status != .cancelled {
                result += CalendarRecurrenceExpander.occurrences(of: event, overrides: [], in: window)
            }
        }
        return result.sorted { $0.start < $1.start }
    }
}
