import Foundation

/// A day-planner slot as the calendar sees it: neutral, so neither module imports the other.
public struct CalendarSlotValue: Equatable, Sendable {
    public let id: UUID
    public var taskID: UUID?
    public var title: String
    public var start: Date
    public var end: Date
    /// RRULE body for a repeating blocked slot.
    public var rrule: String?
    /// The calendar the user chose for this slot; nil means the default.
    public var collectionID: UUID?

    public init(id: UUID, taskID: UUID?, title: String, start: Date, end: Date, rrule: String?, collectionID: UUID?) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.start = start
        self.end = end
        self.rrule = rrule
        self.collectionID = collectionID
    }

    public static let uidPrefix = "makosh-slot-"
    public static func uid(_ id: UUID) -> String { uidPrefix + id.uuidString.lowercased() }
    public static func slotID(fromUID uid: String) -> UUID? {
        uid.hasPrefix(uidPrefix) ? UUID(uuidString: String(uid.dropFirst(uidPrefix.count))) : nil
    }
}

/// Busy time of a day that the planner must not plan over.
public struct CalendarBusyBlock: Equatable, Sendable {
    public let eventID: UUID
    public let title: String
    public let start: Date
    public let end: Date
}

extension CalendarService {
    /// Makes the day's planner slots calendar events (by UID), moves and removes them as the slots change.
    public func syncSlots(day: DateInterval, slots: [CalendarSlotValue], defaultCollectionID: UUID) async throws {
        let collections = try await store.collections()
        let events = try await store.events(collectionIDs: Set(collections.map(\.id)), from: day.start, to: day.end, includeCopies: false)
            .filter { $0.uid.hasPrefix(CalendarSlotValue.uidPrefix) && $0.recurrenceID == nil }
        var existing = Dictionary(events.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for slot in slots {
            let uid = CalendarSlotValue.uid(slot.id)
            let target =
                slot.collectionID.flatMap { id in collections.contains { $0.id == id && $0.access == .write } ? id : nil }
                ?? defaultCollectionID
            let time = CalendarEventTime.timed(start: slot.start, end: slot.end, timeZone: nil)
            guard let event = existing.removeValue(forKey: uid) else {
                _ = try await create(
                    CalendarDraft(
                        collectionID: target, title: slot.title, time: time, recurrence: slot.rrule.map { CalendarRecurrence(rrule: $0) },
                        taskID: slot.taskID), uid: uid, remember: false, ignoringConflicts: true)
                continue
            }
            if event.collectionID != target {
                try await delete(eventID: event.id, occurrenceKey: nil, scope: .series)
                _ = try await create(
                    CalendarDraft(
                        collectionID: target, title: slot.title, time: time, recurrence: slot.rrule.map { CalendarRecurrence(rrule: $0) },
                        taskID: slot.taskID), uid: uid, remember: false, ignoringConflicts: true)
                continue
            }
            var wanted = time
            if event.recurrence != nil, case .timed(let masterStart, _, _) = event.time {
                // A series keeps its first day; only the time of day and the length follow the slot.
                let day = calendar.startOfDay(for: masterStart)
                let offset = slot.start.timeIntervalSince(calendar.startOfDay(for: slot.start))
                wanted = .timed(
                    start: day.addingTimeInterval(offset), end: day.addingTimeInterval(offset + slot.end.timeIntervalSince(slot.start)),
                    timeZone: nil)
            }
            if event.time != wanted || event.title != slot.title || event.recurrence?.rrule != slot.rrule {
                var draft = draft(of: event)
                draft.time = wanted
                draft.title = slot.title
                draft.recurrence = slot.rrule.map { CalendarRecurrence(rrule: $0, exdates: event.recurrence?.exdates ?? []) }
                draft.taskID = slot.taskID
                _ = try await update(eventID: event.id, occurrenceKey: nil, draft: draft, scope: .series, ignoringConflicts: true)
            }
        }
        // Slot events with an occurrence on this day whose slot is gone: the slot was removed.
        for event in existing.values {
            let occurs = !CalendarRecurrenceExpander.occurrences(of: event, overrides: [], in: day).isEmpty
            if occurs { try await delete(eventID: event.id, occurrenceKey: nil, scope: .series) }
        }
    }

    /// Timed busy time of a day in shown calendars, without planner slots and their copies;
    /// a copy whose original is also there counts once.
    public func busyBlocks(day: DateInterval) async throws -> [CalendarBusyBlock] {
        let collections = try await store.collections().filter(\.shown)
        let all = try await store.events(
            collectionIDs: Set(try await store.collections().map(\.id)), from: day.start, to: day.end, includeCopies: true)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let shown = Set(collections.map(\.id))
        var seen = Set<String>()
        var result: [CalendarBusyBlock] = []
        for occurrence in CalendarExpansion.occurrences(all, in: day) where shown.contains(occurrence.collectionID) {
            guard let event = byID[occurrence.eventID], case .timed = occurrence.time, event.givesBusy || event.isBusyCopy else { continue }
            let source = event.busyMarker?.sourceEventID ?? event.masterID ?? event.id
            let original = byID[source]
            if (original ?? event).uid.hasPrefix(CalendarSlotValue.uidPrefix) { continue }
            // A copy whose original is shown is the same commitment.
            if event.isBusyCopy, let original, !original.isBusyCopy, shown.contains(original.collectionID) { continue }
            guard seen.insert("\(source)/\(occurrence.start.timeIntervalSince1970)").inserted else { continue }
            let title = original.flatMap { $0.isBusyCopy ? nil : $0.title } ?? event.title
            result.append(CalendarBusyBlock(eventID: event.id, title: title, start: occurrence.start, end: occurrence.end))
        }
        return result.sorted { $0.start < $1.start }
    }
}
