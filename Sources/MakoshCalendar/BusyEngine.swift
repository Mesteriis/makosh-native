import Foundation

/// A busy copy that should exist: one occurrence of one original in one target calendar.
public struct DesiredBusyCopy: Hashable, Sendable {
    public let sourceEventID: UUID
    public let occurrenceKey: Date
    public let targetCollectionID: UUID
    public let time: CalendarEventTime

    public init(sourceEventID: UUID, occurrenceKey: Date, targetCollectionID: UUID, time: CalendarEventTime) {
        self.sourceEventID = sourceEventID
        self.occurrenceKey = occurrenceKey
        self.targetCollectionID = targetCollectionID
        self.time = time
    }

    var marker: CalendarBusyMarker { CalendarBusyMarker(sourceEventID: sourceEventID, occurrenceStart: occurrenceKey) }
}

extension CalendarEventTime: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .timed(let start, let end, let zone):
            hasher.combine(0)
            hasher.combine(start)
            hasher.combine(end)
            hasher.combine(zone)
        case .allDay(let start, let end):
            hasher.combine(1)
            hasher.combine(start)
            hasher.combine(end)
        }
    }
}

public enum BusyCopyState: String, Codable, Sendable {
    /// Creation attempted, not yet confirmed.
    case pending
    case placed
    case removing
    /// The target calendar is no longer reachable; the copy could not be removed.
    case orphaned
}

/// A busy copy Makosh placed (or is placing) in a target calendar.
public struct BusyCopyRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceEventID: UUID
    public let occurrenceKey: Date
    public let targetCollectionID: UUID
    public var externalID: String?
    public var etag: String?
    public var time: CalendarEventTime
    public var state: BusyCopyState

    public init(
        id: UUID = UUID(), sourceEventID: UUID, occurrenceKey: Date, targetCollectionID: UUID, externalID: String? = nil,
        etag: String? = nil, time: CalendarEventTime, state: BusyCopyState
    ) {
        self.id = id
        self.sourceEventID = sourceEventID
        self.occurrenceKey = occurrenceKey
        self.targetCollectionID = targetCollectionID
        self.externalID = externalID
        self.etag = etag
        self.time = time
        self.state = state
    }

    var end: Date { CalendarOccurrence(eventID: sourceEventID, collectionID: targetCollectionID, time: time, key: occurrenceKey).end }
}

/// A busy copy as read back from a server.
public struct ObservedBusyCopy: Equatable, Sendable {
    public let externalID: String
    public let marker: CalendarBusyMarker
    public let time: CalendarEventTime
    public let collectionID: UUID

    public init(externalID: String, marker: CalendarBusyMarker, time: CalendarEventTime, collectionID: UUID) {
        self.externalID = externalID
        self.marker = marker
        self.time = time
        self.collectionID = collectionID
    }

    var end: Date {
        CalendarOccurrence(eventID: marker.sourceEventID, collectionID: collectionID, time: time, key: marker.occurrenceStart).end
    }
}

public enum BusyAction: Equatable, Sendable {
    case create(DesiredBusyCopy)
    case move(record: BusyCopyRecord, to: CalendarEventTime)
    case remove(BusyCopyRecord)
    /// A copy found on the server after an unknown outcome: take it over instead of creating a second one.
    case adopt(record: DesiredBusyCopy, observed: ObservedBusyCopy)
    case deleteStray(ObservedBusyCopy)
}

/// Which busy copies should exist, and what to do to get there. Pure: the
/// service turns actions into journaled attempts.
public enum BusyEngine {
    public static let horizon: TimeInterval = 90 * 86400

    public static func desired(events: [CalendarEvent], collections: [CalendarCollection], now: Date) -> Set<DesiredBusyCopy> {
        let window = DateInterval(start: now, end: now.addingTimeInterval(horizon))
        let byID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        let live = events.filter { $0.deletedAt == nil && !$0.isBusyCopy && byID[$0.collectionID] != nil }
        var overrides: [String: [CalendarEvent]] = [:]
        for event in live where event.recurrenceID != nil {
            overrides[event.collectionID.uuidString + "/" + event.uid, default: []].append(event)
        }
        var result = Set<DesiredBusyCopy>()
        for master in live where master.recurrenceID == nil {
            let targets = CalendarNeighbours.of(master.collectionID, in: collections).filter { byID[$0]?.access == .write }
            guard !targets.isEmpty else { continue }
            let related = overrides[master.collectionID.uuidString + "/" + master.uid] ?? []
            let byEvent = Dictionary(uniqueKeysWithValues: ([master] + related).map { ($0.id, $0) })
            for occurrence in CalendarRecurrenceExpander.occurrences(of: master, overrides: related, in: window) {
                guard byEvent[occurrence.eventID]?.givesBusy == true, occurrence.end > now else { continue }
                for target in targets {
                    result.insert(
                        DesiredBusyCopy(
                            sourceEventID: master.id, occurrenceKey: occurrence.key, targetCollectionID: target, time: occurrence.time))
                }
            }
        }
        return result
    }

    /// `read` names the target calendars read in this pass: only for them does
    /// a missing, moved or unknown copy on the server mean anything.
    public static func reconcile(
        desired: Set<DesiredBusyCopy>, records: [BusyCopyRecord], observed: [ObservedBusyCopy], read: Set<UUID>, now: Date
    ) -> [BusyAction] {
        struct Key: Hashable {
            let source: UUID, occurrence: Date, target: UUID
        }
        func key(_ d: DesiredBusyCopy) -> Key { Key(source: d.sourceEventID, occurrence: d.occurrenceKey, target: d.targetCollectionID) }
        func key(_ r: BusyCopyRecord) -> Key { Key(source: r.sourceEventID, occurrence: r.occurrenceKey, target: r.targetCollectionID) }
        func key(_ o: ObservedBusyCopy) -> Key {
            Key(source: o.marker.sourceEventID, occurrence: o.marker.occurrenceStart, target: o.collectionID)
        }

        let wanted = Dictionary(desired.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var observedByKey: [Key: [ObservedBusyCopy]] = [:]
        for copy in observed { observedByKey[key(copy), default: []].append(copy) }
        var matched = Set<String>()
        var actions: [BusyAction] = []

        let recorded = Dictionary(records.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        for record in records.sorted(by: { $0.occurrenceKey < $1.occurrenceKey }) {
            let k = key(record)
            let isRead = read.contains(record.targetCollectionID)
            let onServer = record.externalID.flatMap { id in
                observed.first { $0.externalID == id && $0.collectionID == record.targetCollectionID }
            }
            if let onServer { matched.insert(onServer.externalID) }
            guard let goal = wanted[k] else {
                if record.end > now, record.state != .pending || onServer != nil { actions.append(.remove(record)) }
                continue
            }
            switch record.state {
            case .pending:
                if let found = observedByKey[k]?.first {
                    matched.insert(found.externalID)
                    actions.append(.adopt(record: goal, observed: found))
                }
            case .placed, .removing, .orphaned:
                if isRead, onServer == nil {
                    actions.append(.create(goal))
                } else if let onServer, onServer.time != goal.time {
                    actions.append(.move(record: record, to: goal.time))
                } else if record.time != goal.time {
                    actions.append(.move(record: record, to: goal.time))
                }
            }
        }
        for (k, goal) in wanted.sorted(by: { $0.value.occurrenceKey < $1.value.occurrenceKey }) where recorded[k] == nil {
            if let found = observedByKey[k]?.first(where: { !matched.contains($0.externalID) }) {
                matched.insert(found.externalID)
                actions.append(.adopt(record: goal, observed: found))
            } else {
                actions.append(.create(goal))
            }
        }
        for copy in observed where read.contains(copy.collectionID) && !matched.contains(copy.externalID) && copy.end > now {
            actions.append(.deleteStray(copy))
        }
        return actions
    }
}
