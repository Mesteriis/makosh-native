import Foundation

/// How many busy copies a group change would place and remove, per target calendar.
public struct BusyPreview: Equatable, Sendable {
    public var create: [UUID: Int]
    public var remove: [UUID: Int]
}

extension CalendarService {
    public func previewGroupChange(collections: [CalendarCollection], groups: [CalendarGroup]) async throws -> BusyPreview {
        let desired = try await desiredCopies(collections: collections)
        let records = try await store.busyCopies(targetCollectionID: nil)
        let wanted = Set(desired.map { "\($0.sourceEventID)/\($0.occurrenceKey.timeIntervalSince1970)/\($0.targetCollectionID)" })
        let have = Set(records.map { "\($0.sourceEventID)/\($0.occurrenceKey.timeIntervalSince1970)/\($0.targetCollectionID)" })
        var preview = BusyPreview(create: [:], remove: [:])
        for copy in desired
        where !have.contains("\(copy.sourceEventID)/\(copy.occurrenceKey.timeIntervalSince1970)/\(copy.targetCollectionID)") {
            preview.create[copy.targetCollectionID, default: 0] += 1
        }
        for record in records
        where !wanted.contains("\(record.sourceEventID)/\(record.occurrenceKey.timeIntervalSince1970)/\(record.targetCollectionID)") {
            preview.remove[record.targetCollectionID, default: 0] += 1
        }
        return preview
    }

    public func applyGroupChange(collections: [CalendarCollection], groups: [CalendarGroup]) async throws {
        let keep = Set(groups.map(\.id))
        try await store.performInTransaction { store in
            for group in groups { try store.saveGroup(group) }
            for group in try store.groups() where !keep.contains(group.id) { try store.removeGroup(id: group.id) }
            for var collection in collections {
                collection.groupIDs.formIntersection(keep)
                try store.saveCollection(collection)
            }
        }
        reconcileSoon()
    }

    func desiredCopies(collections: [CalendarCollection]) async throws -> Set<DesiredBusyCopy> {
        let accounts = try await store.accounts()
        let live = collections.filter { collection in accounts.first { $0.id == collection.accountID }?.state != .disabled }
        let events = try await store.events(
            collectionIDs: Set(live.map(\.id)), from: now().addingTimeInterval(-86400), to: now().addingTimeInterval(BusyEngine.horizon),
            includeCopies: false)
        return BusyEngine.desired(events: events, collections: live, now: now())
    }

    /// Brings busy copies in line with the originals. `read` names calendars read
    /// in this pass: only there does a missing or moved copy on the server count.
    public func reconcileBusy(read: Set<UUID>) async {
        do { try await reconcile(read: read) } catch {}
    }

    private func reconcile(read: Set<UUID>) async throws {
        let accounts = try await store.accounts(), collections = try await store.collections()
        let preferences = try await store.preferences()
        let accountOf = Dictionary(
            uniqueKeysWithValues: collections.map { collection in (collection.id, accounts.first { $0.id == collection.accountID }) })
        let local = Set(collections.filter { accountOf[$0.id]??.kind == .local }.map(\.id))
        let readNow = read.union(local)
        var observed: [ObservedBusyCopy] = []
        for collection in collections {
            for event in try await store.liveEvents(collectionID: collection.id) {
                guard let marker = event.busyMarker else { continue }
                observed.append(
                    ObservedBusyCopy(
                        externalID: event.externalID ?? event.id.uuidString, marker: marker, time: event.time, collectionID: collection.id))
            }
        }
        var records = try await store.busyCopies(targetCollectionID: nil)
        // A pending copy whose unknown create left nothing on a calendar just read: rejected, then created anew.
        for record in records where record.state == .pending && readNow.contains(record.targetCollectionID) {
            let present = observed.contains {
                $0.collectionID == record.targetCollectionID
                    && $0.marker == CalendarBusyMarker(sourceEventID: record.sourceEventID, occurrenceStart: record.occurrenceKey)
            }
            guard !present else { continue }
            for attempt in try await store.openAttempts() where attempt.copyID == record.id {
                try await store.settle(attempt.id, state: .rejected, failure: .rejected(code: 404, stage: "copy"))
            }
            try await store.removeBusyCopy(id: record.id)
        }
        records = try await store.busyCopies(targetCollectionID: nil)
        let desired = try await desiredCopies(collections: collections)
        let actions = BusyEngine.reconcile(desired: desired, records: records, observed: observed, read: readNow, now: now())
        var known: [String: BusyCopyRecord] = [:]
        for record in records { known[Self.recordKey(record.sourceEventID, record.occurrenceKey, record.targetCollectionID)] = record }

        var written: [UUID: Int] = [:]
        var blocked = Set<UUID>()
        for action in actions {
            let target: UUID
            switch action {
            case .create(let copy): target = copy.targetCollectionID
            case .move(let record, _), .remove(let record): target = record.targetCollectionID
            case .adopt(let copy, _): target = copy.targetCollectionID
            case .deleteStray(let copy): target = copy.collectionID
            }
            guard let collection = collections.first(where: { $0.id == target }), let account = accountOf[target] ?? nil,
                !blocked.contains(account.id)
            else { continue }
            if case .adopt = action {
            } else {
                guard written[target, default: 0] < preferences.maxWritesPerPass else { continue }
                written[target, default: 0] += 1
            }
            let existing: BusyCopyRecord?
            switch action {
            case .create(let copy), .adopt(let copy, _):
                existing = known[Self.recordKey(copy.sourceEventID, copy.occurrenceKey, collection.id)]
            default: existing = nil
            }
            if account.kind == .local {
                try await applyLocal(action, collection: collection, existing: existing)
                continue
            }
            guard account.state == .connected || account.state == .unreachable else { continue }
            let outcome = await applyRemote(action, collection: collection, account: account, existing: existing)
            if outcome == .needsSignIn || outcome == .adminBlocked { blocked.insert(account.id) }
        }
        // Creates whose answer was lost and whose event now came back by UID need no check.
        for attempt in try await store.openAttempts() where attempt.kind == .createEvent && attempt.state == .unknown {
            guard let eventID = attempt.eventID, let event = try await store.event(id: eventID), event.externalID != nil,
                event.attendees.isEmpty
            else { continue }
            try await store.settle(attempt.id, state: .confirmed, failure: nil)
        }
    }

    private func copyEvent(
        _ time: CalendarEventTime, marker: CalendarBusyMarker, collection: CalendarCollection, externalID: String?, etag: String?
    )
        -> CalendarEvent
    {
        CalendarEvent(
            collectionID: collection.id, externalID: externalID, uid: CalDAVAdapter.busyUID(marker), title: "Занято", time: time,
            busyMarker: marker,
            etag: etag)
    }

    static func recordKey(_ source: UUID, _ occurrence: Date, _ target: UUID) -> String {
        "\(source)/\(occurrence.timeIntervalSince1970)/\(target)"
    }

    private func applyLocal(_ action: BusyAction, collection: CalendarCollection, existing: BusyCopyRecord?) async throws {
        switch action {
        case .create(let copy), .adopt(let copy, _):
            if case .adopt(_, let found) = action, let id = UUID(uuidString: found.externalID) {
                try await store.saveBusyCopy(
                    BusyCopyRecord(
                        sourceEventID: copy.sourceEventID, occurrenceKey: copy.occurrenceKey, targetCollectionID: collection.id,
                        externalID: id.uuidString,
                        time: found.time, state: .placed))
                return
            }
            let event = try await store.insert(
                copyEvent(copy.time, marker: copy.marker, collection: collection, externalID: nil, etag: nil), actor: .engine)
            var record =
                existing
                ?? BusyCopyRecord(
                    sourceEventID: copy.sourceEventID, occurrenceKey: copy.occurrenceKey, targetCollectionID: collection.id,
                    time: copy.time, state: .placed)
            record.externalID = event.id.uuidString
            record.time = copy.time
            record.state = .placed
            try await store.saveBusyCopy(record)
        case .move(var record, let time):
            if let id = record.externalID.flatMap(UUID.init(uuidString:)), var event = try await store.event(id: id), event.deletedAt == nil
            {
                let revision = event.revision
                event.time = time
                _ = try await store.update(event, expectedRevision: revision, actor: .engine)
            } else {
                let event = try await store.insert(
                    copyEvent(
                        time, marker: CalendarBusyMarker(sourceEventID: record.sourceEventID, occurrenceStart: record.occurrenceKey),
                        collection: collection, externalID: nil, etag: nil),
                    actor: .engine)
                record.externalID = event.id.uuidString
            }
            record.time = time
            record.state = .placed
            try await store.saveBusyCopy(record)
        case .remove(let record):
            if let id = record.externalID.flatMap(UUID.init(uuidString:)), let event = try await store.event(id: id), event.deletedAt == nil
            {
                try await store.markDeleted(id: id, expectedRevision: event.revision, actor: .engine)
            }
            try await store.removeBusyCopy(id: record.id)
        case .deleteStray(let copy):
            if let id = UUID(uuidString: copy.externalID), let event = try await store.event(id: id), event.deletedAt == nil {
                try await store.markDeleted(id: id, expectedRevision: event.revision, actor: .engine)
            }
        }
    }

    /// One remote busy-copy write through the journal; returns the account state it implies.
    private func applyRemote(
        _ action: BusyAction, collection: CalendarCollection, account: CalendarAccount, existing: BusyCopyRecord?
    ) async
        -> CalendarAccountState
    {
        do {
            let adapter = try await adapter(for: account)
            switch action {
            case .create(let copy):
                // A copy removed on the server is created again under its existing record.
                var record =
                    existing
                    ?? BusyCopyRecord(
                        sourceEventID: copy.sourceEventID, occurrenceKey: copy.occurrenceKey, targetCollectionID: collection.id,
                        time: copy.time, state: .pending)
                record.externalID = nil
                record.etag = nil
                record.time = copy.time
                record.state = .pending
                try await store.saveBusyCopy(record)
                try await journaled(.createCopy, copyID: record.id, collection: collection, account: account) {
                    let ref = try await adapter.createBusyCopy(copy, in: collection)
                    var placed = record
                    placed.externalID = ref.externalID
                    placed.etag = ref.etag
                    placed.state = .placed
                    try await self.store.saveBusyCopy(placed)
                    try await self.store.observe(
                        self.copyEvent(copy.time, marker: copy.marker, collection: collection, externalID: ref.externalID, etag: ref.etag),
                        collectionID: collection.id)
                }
            case .move(let record, let time):
                guard let externalID = record.externalID else { return account.state }
                let marker = CalendarBusyMarker(sourceEventID: record.sourceEventID, occurrenceStart: record.occurrenceKey)
                try await journaled(.moveCopy, copyID: record.id, collection: collection, account: account) {
                    let observedEtag = try await self.store.event(externalID: externalID, collectionID: collection.id)?.etag
                    let ref = try await adapter.moveBusyCopy(
                        ref: RemoteEventRef(externalID: externalID, etag: observedEtag ?? record.etag), to: time, marker: marker,
                        in: collection)
                    var moved = record
                    moved.time = time
                    moved.etag = ref.etag
                    moved.state = .placed
                    try await self.store.saveBusyCopy(moved)
                    try await self.store.observe(
                        self.copyEvent(time, marker: marker, collection: collection, externalID: externalID, etag: ref.etag),
                        collectionID: collection.id)
                }
            case .remove(let record):
                guard let externalID = record.externalID else {
                    try await store.removeBusyCopy(id: record.id)
                    return account.state
                }
                try await journaled(.deleteCopy, copyID: record.id, collection: collection, account: account) {
                    try await adapter.delete(ref: RemoteEventRef(externalID: externalID, etag: nil), in: collection, notify: false)
                    try await self.store.removeBusyCopy(id: record.id)
                    try await self.store.observeRemoval(externalID: externalID, collectionID: collection.id)
                }
            case .adopt(let copy, let found):
                var record =
                    existing
                    ?? BusyCopyRecord(
                        sourceEventID: copy.sourceEventID, occurrenceKey: copy.occurrenceKey, targetCollectionID: collection.id,
                        time: found.time, state: .placed)
                record.externalID = found.externalID
                record.time = found.time
                record.state = .placed
                record.etag = try await store.event(externalID: found.externalID, collectionID: collection.id)?.etag
                try await store.saveBusyCopy(record)
                for attempt in try await store.openAttempts() where attempt.copyID == record.id {
                    try await store.settle(attempt.id, state: .confirmed, failure: nil)
                }
            case .deleteStray(let found):
                try await journaled(.deleteCopy, copyID: nil, collection: collection, account: account) {
                    try await adapter.delete(ref: RemoteEventRef(externalID: found.externalID, etag: nil), in: collection, notify: false)
                    try await self.store.observeRemoval(externalID: found.externalID, collectionID: collection.id)
                }
            }
            return account.state
        } catch let failure as CalendarFailure {
            return Self.state(after: failure)
        } catch {
            return account.state
        }
    }

    private func journaled(
        _ kind: CalendarAttemptKind, copyID: UUID?, collection: CalendarCollection, account: CalendarAccount,
        _ body: () async throws -> Void
    ) async throws {
        let attempt: CalendarAttempt
        do {
            attempt = try await store.beginAttempt(kind: kind, eventID: nil, copyID: copyID, collectionID: collection.id, payload: Data())
        } catch CalendarFailure.invalidInput("attempt open") {
            return
        }
        do {
            try await store.markSent(attempt.id)
            try await body()
            try await store.settle(attempt.id, state: .confirmed, failure: nil)
        } catch {
            let state = try await fail(attempt, error: error, accountID: account.id)
            if state == .rejected, kind == .createCopy, let copyID { try await store.removeBusyCopy(id: copyID) }
            throw Self.surface(error)
        }
    }
}
