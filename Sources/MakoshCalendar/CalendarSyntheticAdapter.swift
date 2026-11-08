import Foundation

/// An in-memory calendar server for tests and the isolated QA bundle. It never
/// touches the network. `failNext(.unknownOutcome)` applies the write and then
/// throws, as a dropped connection after the server committed would.
public actor CalendarSyntheticAdapter: CalendarAdapter {
    private var remote: [RemoteCollection]
    private var store: [String: [String: CalendarEvent]] = [:]
    private var log: [(revision: Int, collection: String, externalID: String, removed: Bool)] = []
    private var revision = 0
    private var counter = 0
    private var failure: CalendarFailure?
    private var readFailure: CalendarFailure?
    private var failureApplies = true
    private var brokenCollections: [String: CalendarFailure] = [:]
    /// Simulated network time per write, so concurrent passes interleave in tests.
    public var writeDelay: Duration = .zero
    /// How many times `changes` ran: lets tests see the polling schedule.
    public private(set) var reads = 0
    private let schedules: Bool
    public private(set) var sentInvitations: [String] = []

    public init(collections: [RemoteCollection], events: [String: [CalendarEvent]], schedules: Bool = true) {
        remote = collections
        self.schedules = schedules
        for (collection, list) in events {
            for var event in list {
                revision += 1
                counter += 1
                let fallback = "syn-\(counter)"
                let id = event.externalID ?? fallback
                event.externalID = id
                event.etag = "\"\(revision)\""
                store[collection, default: [:]][id] = event
                log.append((revision, collection, id, false))
            }
        }
    }

    public var schedulesInvitations: Bool { get async { schedules } }

    public func failNext(_ failure: CalendarFailure) {
        self.failure = failure
        failureApplies = true
    }

    /// An unknown outcome whose write never reached the server.
    public func failNextWithoutApplying(_ failure: CalendarFailure) {
        self.failure = failure
        failureApplies = false
    }

    public func setWriteDelay(_ delay: Duration) { writeDelay = delay }

    /// A calendar that now fails on read (deleted or unshared on the server).
    public func breakCollection(_ externalID: String, with failure: CalendarFailure) { brokenCollections[externalID] = failure }

    /// A calendar created or shared on the server after the account was connected.
    public func addCollection(_ collection: RemoteCollection) { remote.append(collection) }

    /// Every read and listing throws `failure` until cleared with nil.
    public func failReads(_ failure: CalendarFailure?) { readFailure = failure }

    public func externalEvents(collectionExternalID: String) -> [CalendarEvent] {
        (store[collectionExternalID] ?? [:]).values.sorted { ($0.externalID ?? "") < ($1.externalID ?? "") }
    }

    /// Moves an event as if someone edited it directly on the server.
    public func tamper(externalID: String, collectionExternalID: String, shiftMinutes: Int) {
        guard var event = store[collectionExternalID]?[externalID] else { return }
        let shift = TimeInterval(shiftMinutes * 60)
        if case .timed(let start, let end, let zone) = event.time {
            event.time = .timed(start: start + shift, end: end + shift, timeZone: zone)
        }
        put(event, collection: collectionExternalID)
    }

    /// Removes an event as if someone deleted it on the server.
    public func remove(externalID: String, collectionExternalID: String) {
        guard store[collectionExternalID]?.removeValue(forKey: externalID) != nil else { return }
        revision += 1
        log.append((revision, collectionExternalID, externalID, true))
    }

    public func addRemote(_ event: CalendarEvent, collectionExternalID: String) -> String {
        counter += 1
        var event = event
        let fallback = "syn-\(counter)"
        let id = event.externalID ?? fallback
        event.externalID = id
        put(event, collection: collectionExternalID)
        return id
    }

    private func put(_ event: CalendarEvent, collection: String) {
        revision += 1
        var event = event
        event.etag = "\"\(revision)\""
        store[collection, default: [:]][event.externalID!] = event
        log.append((revision, collection, event.externalID!, false))
    }

    private func pause() async {
        if writeDelay > .zero { try? await Task.sleep(for: writeDelay) }
    }

    /// Throws the injected failure; an unknown outcome applies `body` first.
    private func write<T>(_ body: () throws -> T) throws -> T {
        guard let pending = failure else { return try body() }
        failure = nil
        if case .unknownOutcome = pending, failureApplies { _ = try body() }
        throw pending
    }

    public func collections() async throws -> [RemoteCollection] {
        if let readFailure { throw readFailure }
        return remote
    }

    public func changes(collection: CalendarCollection, cursor: Data?, window: DateInterval) async throws -> RemoteChangeSet {
        reads += 1
        await pause()
        if let readFailure { throw readFailure }
        if let broken = brokenCollections[collection.externalID] { throw broken }
        let since = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        let entries = log.filter { $0.collection == collection.externalID && $0.revision > (since ?? 0) }
        var result = RemoteChangeSet(cursor: Data(String(revision).utf8), full: since == nil)
        var seen = Set<String>()
        for entry in entries.reversed() where !seen.contains(entry.externalID) {
            seen.insert(entry.externalID)
            if let event = store[collection.externalID]?[entry.externalID] {
                var copy = event
                copy.collectionID = collection.id
                result.events.append(copy)
                if let marker = copy.busyMarker {
                    result.busyCopies.append(
                        ObservedBusyCopy(externalID: entry.externalID, marker: marker, time: copy.time, collectionID: collection.id))
                }
            } else if since != nil {
                result.removedExternalIDs.append(entry.externalID)
            }
        }
        if since == nil {
            // A full read lists every live copy, not just the logged ones.
            result.busyCopies = (store[collection.externalID] ?? [:]).values.compactMap { event in
                event.busyMarker.map {
                    ObservedBusyCopy(externalID: event.externalID!, marker: $0, time: event.time, collectionID: collection.id)
                }
            }
        }
        return result
    }

    public func create(_ event: CalendarEvent, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef {
        await pause()
        return try write {
            counter += 1
            var stored = event
            stored.externalID = "syn-\(counter)"
            if !schedules { stored.attendees = [] }
            put(stored, collection: collection.externalID)
            if notify, !stored.attendees.isEmpty { sentInvitations.append(event.uid) }
            return RemoteEventRef(externalID: stored.externalID!, etag: store[collection.externalID]![stored.externalID!]!.etag)
        }
    }

    public func update(
        _ event: CalendarEvent, ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool
    ) async throws
        -> RemoteEventRef
    {
        await pause()
        return try write {
            guard store[collection.externalID]?[ref.externalID] != nil else { throw CalendarFailure.rejected(code: 404, stage: "update") }
            var stored = event
            stored.externalID = ref.externalID
            put(stored, collection: collection.externalID)
            if notify, !stored.attendees.isEmpty { sentInvitations.append(event.uid) }
            return RemoteEventRef(externalID: ref.externalID, etag: store[collection.externalID]![ref.externalID]!.etag)
        }
    }

    public func delete(ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws {
        await pause()
        return try write { remove(externalID: ref.externalID, collectionExternalID: collection.externalID) }
    }

    public func respond(_ response: CalendarResponse, ref: RemoteEventRef, in collection: CalendarCollection) async throws -> RemoteEventRef
    {
        await pause()
        return try write {
            guard var event = store[collection.externalID]?[ref.externalID], let index = event.attendees.firstIndex(where: \.isSelf) else {
                throw CalendarFailure.invalidInput("not invited")
            }
            event.attendees[index].response = response
            put(event, collection: collection.externalID)
            return RemoteEventRef(externalID: ref.externalID, etag: store[collection.externalID]![ref.externalID]!.etag)
        }
    }

    public func find(uid: String, in collection: CalendarCollection) async throws -> CalendarEvent? {
        (store[collection.externalID] ?? [:]).values.first { $0.uid == uid && $0.recurrenceID == nil }
    }

    public func createBusyCopy(_ copy: DesiredBusyCopy, in collection: CalendarCollection) async throws -> RemoteEventRef {
        await pause()
        return try write {
            counter += 1
            let event = CalendarEvent(
                collectionID: collection.id, externalID: "syn-busy-\(counter)", uid: "busy-\(counter)", title: "Занято", time: copy.time,
                busyMarker: copy.marker)
            put(event, collection: collection.externalID)
            return RemoteEventRef(externalID: event.externalID!, etag: store[collection.externalID]![event.externalID!]!.etag)
        }
    }

    public func moveBusyCopy(
        ref: RemoteEventRef, to time: CalendarEventTime, marker: CalendarBusyMarker, in collection: CalendarCollection
    )
        async throws -> RemoteEventRef
    {
        await pause()
        return try write {
            guard var event = store[collection.externalID]?[ref.externalID] else {
                throw CalendarFailure.rejected(code: 404, stage: "copy")
            }
            event.time = time
            event.busyMarker = marker
            put(event, collection: collection.externalID)
            return RemoteEventRef(externalID: ref.externalID, etag: store[collection.externalID]![ref.externalID]!.etag)
        }
    }
}
