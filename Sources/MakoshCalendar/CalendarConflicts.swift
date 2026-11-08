import Foundation

public enum CalendarNeighbours {
    /// Calendars sharing at least one busy group with `collectionID`, without itself.
    public static func of(_ collectionID: UUID, in collections: [CalendarCollection]) -> Set<UUID> {
        guard let groups = collections.first(where: { $0.id == collectionID })?.groupIDs, !groups.isEmpty else { return [] }
        return Set(collections.filter { $0.id != collectionID && !$0.groupIDs.isDisjoint(with: groups) }.map(\.id))
    }
}

public struct CalendarConflict: Equatable, Identifiable, Sendable {
    public let eventID: UUID
    public let collectionID: UUID
    public let start: Date
    public let end: Date
    public let isBusyCopy: Bool
    /// The user is an attendee, not the organizer: «Не приду» applies.
    public let isInvitation: Bool
    public var id: String { eventID.uuidString + "." + String(start.timeIntervalSince1970) }

    public init(eventID: UUID, collectionID: UUID, start: Date, end: Date, isBusyCopy: Bool, isInvitation: Bool) {
        self.eventID = eventID
        self.collectionID = collectionID
        self.start = start
        self.end = end
        self.isBusyCopy = isBusyCopy
        self.isInvitation = isInvitation
    }
}

/// Overlaps with the actual busy time of a calendar and its group neighbours:
/// originals that give busy time and Makosh busy copies. Touching ends do not overlap.
public enum CalendarConflictFinder {
    public static func conflicts(
        start: Date, end: Date, collectionID: UUID, excluding eventID: UUID?, occurrences: [CalendarOccurrence],
        events: [UUID: CalendarEvent], collections: [CalendarCollection]
    ) -> [CalendarConflict] {
        let scope = CalendarNeighbours.of(collectionID, in: collections).union([collectionID])
        return busy(in: scope, occurrences: occurrences, events: events, excluding: eventID).filter { $0.0.start < end && $0.0.end > start }
            .map { occurrence, event in
                CalendarConflict(
                    eventID: event.id, collectionID: occurrence.collectionID, start: occurrence.start, end: occurrence.end,
                    isBusyCopy: event.isBusyCopy,
                    isInvitation: event.attendees.contains { $0.isSelf && !$0.isOrganizer }
                        && !(event.organizerEmail.map { organizer in
                            event.attendees.contains { $0.isSelf && $0.email.caseInsensitiveCompare(organizer) == .orderedSame }
                        } ?? false))
            }
            .sorted { $0.start < $1.start }
    }

    /// The first start at or after `after`, on a `step` grid, where `length` fits without overlap.
    public static func nearestFree(
        length: TimeInterval, after: Date, collectionID: UUID, occurrences: [CalendarOccurrence], events: [UUID: CalendarEvent],
        collections: [CalendarCollection], step: TimeInterval = 900, horizon: TimeInterval = 7 * 86400
    ) -> Date? {
        let scope = CalendarNeighbours.of(collectionID, in: collections).union([collectionID])
        let taken = busy(in: scope, occurrences: occurrences, events: events, excluding: nil).map { ($0.0.start, $0.0.end) }
        var candidate = after
        let limit = after.addingTimeInterval(horizon)
        while candidate < limit {
            let end = candidate.addingTimeInterval(length)
            if let blocking = taken.filter({ $0.0 < end && $0.1 > candidate }).map(\.1).max() {
                // Jump past the blocking time, staying on the grid measured from `after`.
                let offset = blocking.timeIntervalSince(after)
                candidate = after.addingTimeInterval((offset / step).rounded(.up) * step)
            } else {
                return candidate
            }
        }
        return nil
    }

    static func busy(
        in scope: Set<UUID>, occurrences: [CalendarOccurrence], events: [UUID: CalendarEvent], excluding eventID: UUID?
    )
        -> [(CalendarOccurrence, CalendarEvent)]
    {
        occurrences.compactMap { occurrence in
            guard scope.contains(occurrence.collectionID), occurrence.eventID != eventID, let event = events[occurrence.eventID],
                event.givesBusy || (event.isBusyCopy && event.deletedAt == nil)
            else { return nil }
            if let eventID, event.masterID == eventID { return nil }
            return (occurrence, event)
        }
    }
}
