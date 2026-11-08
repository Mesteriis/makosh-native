import Foundation

public enum CalendarEditScope: String, Sendable {
    case occurrence, series
}

/// What the user asks to write; the service builds the event.
public struct CalendarDraft: Sendable {
    public var collectionID: UUID
    public var title: String
    public var notes: String
    public var location: String
    public var time: CalendarEventTime
    public var recurrence: CalendarRecurrence?
    public var attendees: [String]
    public var reminders: [Int]?
    public var meetingURL: URL?
    public var transparency: CalendarTransparency
    public var taskID: UUID?

    public init(
        collectionID: UUID, title: String, notes: String = "", location: String = "", time: CalendarEventTime,
        recurrence: CalendarRecurrence? = nil, attendees: [String] = [], reminders: [Int]? = nil, meetingURL: URL? = nil,
        transparency: CalendarTransparency = .busy, taskID: UUID? = nil
    ) {
        self.collectionID = collectionID
        self.title = title
        self.notes = notes
        self.location = location
        self.time = time
        self.recurrence = recurrence
        self.attendees = attendees
        self.reminders = reminders
        self.meetingURL = meetingURL
        self.transparency = transparency
        self.taskID = taskID
    }
}

public enum CalendarWriteOutcome: Sendable {
    case saved(CalendarEvent)
    case conflicts([CalendarConflict])
    /// The server's answer is unknown: nothing is resent until a check or a dismissal.
    case attemptOpen(CalendarAttempt)
}

struct CalendarAttemptPayload: Codable {
    var uid: String
    var response: CalendarResponse?
}

extension CalendarService {
    // MARK: Commands

    public func create(_ draft: CalendarDraft, ignoringConflicts: Bool) async throws -> CalendarWriteOutcome {
        try await create(draft, uid: nil, remember: true, ignoringConflicts: ignoringConflicts)
    }

    func create(_ draft: CalendarDraft, uid: String?, remember: Bool, ignoringConflicts: Bool) async throws -> CalendarWriteOutcome {
        let (collection, account) = try await context(draft.collectionID)
        if account.kind == .local, !draft.attendees.isEmpty { throw CalendarFailure.invalidInput("local calendar has no attendees") }
        var event = CalendarEvent(
            collectionID: collection.id, uid: uid ?? UUID().uuidString.lowercased() + "@makosh", title: draft.title, time: draft.time)
        fill(&event, from: draft)
        if !ignoringConflicts {
            let found = try await conflicts(for: event, excluding: nil)
            if !found.isEmpty { return .conflicts(found) }
        }
        if remember {
            var preferences = try await store.preferences()
            preferences.lastCollectionID = collection.id
            try await store.savePreferences(preferences)
        }
        let saved = try await store.insert(event, actor: .user)
        guard account.kind != .local else {
            reconcileSoon()
            return .saved(saved)
        }
        return try await push(.createEvent, event: saved, account: account, collection: collection, undo: .delete) { adapter in
            try await adapter.create(saved, in: collection, notify: !saved.attendees.isEmpty)
        }
    }

    public func move(
        eventID: UUID, occurrenceKey: Date?, to time: CalendarEventTime, scope: CalendarEditScope, ignoringConflicts: Bool
    )
        async throws -> CalendarWriteOutcome
    {
        let event = try await editable(eventID)
        var draft = draft(of: event)
        draft.time = time
        return try await update(
            eventID: eventID, occurrenceKey: occurrenceKey, draft: draft, scope: scope, ignoringConflicts: ignoringConflicts)
    }

    public func update(
        eventID: UUID, occurrenceKey: Date?, draft: CalendarDraft, scope: CalendarEditScope, ignoringConflicts: Bool
    )
        async throws -> CalendarWriteOutcome
    {
        let event = try await editable(eventID)
        guard draft.collectionID == event.collectionID else { throw CalendarFailure.invalidInput("move between calendars") }
        let (collection, account) = try await context(event.collectionID)
        if account.kind == .local, !draft.attendees.isEmpty { throw CalendarFailure.invalidInput("local calendar has no attendees") }

        if event.recurrence != nil, scope == .occurrence, let key = occurrenceKey {
            if account.kind == .local {
                var override = CalendarEvent(
                    collectionID: collection.id, uid: event.uid, title: draft.title, time: draft.time, recurrenceID: key, masterID: event.id
                )
                fill(&override, from: draft)
                override.recurrence = nil
                if !ignoringConflicts {
                    let found = try await conflicts(for: override, excluding: event.id)
                    if !found.isEmpty { return .conflicts(found) }
                }
                if let existing = try await store.events(uid: event.uid, collectionID: collection.id).first(where: {
                    $0.recurrenceID == key
                }) {
                    var changed = existing
                    fill(&changed, from: draft)
                    changed.recurrence = nil
                    let saved = try await store.update(changed, expectedRevision: existing.revision, actor: .user)
                    reconcileSoon()
                    return .saved(saved)
                }
                let saved = try await store.insert(override, actor: .user)
                reconcileSoon()
                return .saved(saved)
            }
            // External series: «только это» splits the occurrence off as its own event.
            guard event.attendees.isEmpty else { throw CalendarFailure.invalidInput("occurrence of shared series") }
            var single = draft
            single.recurrence = nil
            let outcome = try await create(single, ignoringConflicts: ignoringConflicts)
            guard case .saved = outcome else { return outcome }
            var master = event
            master.recurrence?.exdates.append(key)
            _ = try await writeExisting(master, previous: event, account: account, collection: collection)
            return outcome
        }

        var changed = event
        if event.recurrence != nil, let key = occurrenceKey, case .timed(let from, let to, let zone) = draft.time,
            case .timed(let masterStart, _, _) = event.time
        {
            // Moving the whole series from one of its occurrences shifts the series by the same amount.
            let shift = from.timeIntervalSince(key)
            changed.time = .timed(start: masterStart + shift, end: masterStart + shift + to.timeIntervalSince(from), timeZone: zone)
            var rest = draft
            rest.time = changed.time
            fill(&changed, from: rest)
        } else {
            fill(&changed, from: draft)
        }
        if !ignoringConflicts {
            let found = try await conflicts(for: changed, excluding: event.id)
            if !found.isEmpty { return .conflicts(found) }
        }
        return try await writeExisting(changed, previous: event, account: account, collection: collection)
    }

    public func delete(eventID: UUID, occurrenceKey: Date?, scope: CalendarEditScope) async throws {
        let event = try await editable(eventID)
        let (collection, account) = try await context(event.collectionID)
        if let key = occurrenceKey, scope == .occurrence, event.recurrence != nil {
            var master = event
            master.recurrence?.exdates.append(key)
            if let override = try await store.events(uid: event.uid, collectionID: collection.id).first(where: { $0.recurrenceID == key }) {
                try await store.markDeleted(id: override.id, expectedRevision: override.revision, actor: .user)
            }
            _ = try await writeExisting(master, previous: event, account: account, collection: collection)
            return
        }
        if account.kind == .local {
            try await store.markDeleted(id: event.id, expectedRevision: event.revision, actor: .user)
            reconcileSoon()
            return
        }
        if event.recurrenceID != nil, let masterID = event.masterID, let master = try await store.event(id: masterID) {
            // An external override goes as an exception date on its series.
            try await delete(eventID: master.id, occurrenceKey: event.recurrenceID, scope: .occurrence)
            return
        }
        guard let externalID = event.externalID else { throw CalendarFailure.invalidInput("attempt open") }
        let ref = RemoteEventRef(externalID: externalID, etag: event.etag)
        let attempt = try await begin(.deleteEvent, eventID: event.id, collectionID: collection.id, payload: .init(uid: event.uid))
        do {
            let adapter = try await adapter(for: account)
            try await store.markSent(attempt.id)
            try await adapter.delete(ref: ref, in: collection, notify: !event.attendees.isEmpty)
            try await store.settle(attempt.id, state: .confirmed, failure: nil)
            try await store.markDeleted(id: event.id, expectedRevision: event.revision, actor: .user)
            reconcileSoon()
        } catch {
            try await fail(attempt, error: error, accountID: account.id)
            throw Self.surface(error)
        }
    }

    public func respond(eventID: UUID, _ response: CalendarResponse) async throws {
        let event = try await editable(eventID)
        let (collection, account) = try await context(event.collectionID)
        guard account.kind != .local, let externalID = event.externalID, event.attendees.contains(where: \.isSelf) else {
            throw CalendarFailure.invalidInput("not invited")
        }
        let attempt = try await begin(
            .respond, eventID: event.id, collectionID: collection.id, payload: .init(uid: event.uid, response: response))
        do {
            let adapter = try await adapter(for: account)
            try await store.markSent(attempt.id)
            let ref = try await adapter.respond(response, ref: RemoteEventRef(externalID: externalID, etag: event.etag), in: collection)
            try await store.settle(attempt.id, state: .confirmed, failure: nil)
            var changed = event
            for index in changed.attendees.indices where changed.attendees[index].isSelf { changed.attendees[index].response = response }
            changed.etag = ref.etag
            _ = try await store.update(changed, expectedRevision: event.revision, actor: .engine)
            reconcileSoon()
        } catch {
            try await fail(attempt, error: error, accountID: account.id)
            throw Self.surface(error)
        }
    }

    /// Settles an unknown write by reading the server, never by writing again.
    public func check(attemptID: UUID) async throws -> CalendarAttemptState {
        guard let attempt = try await store.attempt(id: attemptID) else { throw CalendarFailure.notFound }
        guard attempt.state.isOpen else { return attempt.state }
        let (collection, account) = try await context(attempt.collectionID)
        let adapter = try await adapter(for: account)
        switch attempt.kind {
        case .createCopy, .moveCopy, .deleteCopy:
            await sync(accountID: account.id)
            return try await store.attempt(id: attemptID)?.state ?? .rejected
        case .createEvent, .updateEvent, .deleteEvent, .respond:
            let payload = try JSONDecoder().decode(CalendarAttemptPayload.self, from: attempt.payload)
            let found = try await adapter.find(uid: payload.uid, in: collection)
            let state: CalendarAttemptState
            switch attempt.kind {
            case .deleteEvent: state = found == nil ? .confirmed : .rejected
            case .respond: state = found?.selfResponse == payload.response ? .confirmed : .rejected
            default: state = found == nil ? .rejected : .confirmed
            }
            if let found, state == .confirmed, attempt.kind != .deleteEvent { try await store.observe(found, collectionID: collection.id) }
            try await store.settle(attemptID, state: state, failure: state == .rejected ? .rejected(code: 404, stage: "check") : nil)
            if let eventID = attempt.eventID, let event = try await store.event(id: eventID), event.deletedAt == nil {
                if (attempt.kind == .createEvent && state == .rejected) || (attempt.kind == .deleteEvent && state == .confirmed) {
                    try await store.markDeleted(id: eventID, expectedRevision: event.revision, actor: .engine)
                }
            }
            reconcileSoon()
            return state
        }
    }

    /// «Отказаться»: the user gives up on an unknown write; nothing is sent.
    public func dismiss(attemptID: UUID) async throws {
        guard let attempt = try await store.attempt(id: attemptID), attempt.state.isOpen else { return }
        try await store.settle(attemptID, state: .rejected, failure: nil)
        if attempt.kind == .createEvent, let eventID = attempt.eventID, let event = try await store.event(id: eventID),
            event.externalID == nil,
            event.deletedAt == nil
        {
            try await store.markDeleted(id: eventID, expectedRevision: event.revision, actor: .user)
        }
        reconcileSoon()
    }

    public func nearestFree(length: TimeInterval, after: Date, collectionID: UUID) async throws -> Date? {
        let collections = try await store.collections()
        let scope = CalendarNeighbours.of(collectionID, in: collections).union([collectionID])
        let window = DateInterval(start: after.addingTimeInterval(-86400), duration: 8 * 86400)
        let events = try await store.events(collectionIDs: scope, from: window.start, to: window.end, includeCopies: true)
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        return CalendarConflictFinder.nearestFree(
            length: length, after: after, collectionID: collectionID, occurrences: CalendarExpansion.occurrences(events, in: window),
            events: byID,
            collections: collections)
    }

    // MARK: Helpers

    func context(_ collectionID: UUID) async throws -> (CalendarCollection, CalendarAccount) {
        guard let collection = try await store.collections().first(where: { $0.id == collectionID }) else { throw CalendarFailure.notFound }
        let account = try await account(collection.accountID)
        guard collection.access == .write, account.state != .disabled else { throw CalendarFailure.invalidInput("read only") }
        return (collection, account)
    }

    func editable(_ eventID: UUID) async throws -> CalendarEvent {
        guard let event = try await store.event(id: eventID), event.deletedAt == nil else { throw CalendarFailure.notFound }
        guard !event.isBusyCopy else { throw CalendarFailure.invalidInput("busy copy") }
        return event
    }

    func draft(of event: CalendarEvent) -> CalendarDraft {
        CalendarDraft(
            collectionID: event.collectionID, title: event.title, notes: event.notes, location: event.location, time: event.time,
            recurrence: event.recurrence, attendees: event.attendees.filter { !$0.isSelf && !$0.isOrganizer }.map(\.email),
            reminders: event.reminders, meetingURL: event.meetingURL, transparency: event.transparency, taskID: event.taskID)
    }

    /// Copies the draft's fields onto an event, keeping known attendees' answers.
    func fill(_ event: inout CalendarEvent, from draft: CalendarDraft) {
        event.title = draft.title
        event.notes = draft.notes
        event.location = draft.location
        event.time = draft.time
        event.recurrence = draft.recurrence
        let kept = event.attendees.filter { $0.isSelf || $0.isOrganizer }
        let known = Dictionary(event.attendees.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        event.attendees =
            kept
            + draft.attendees.filter { email in !kept.contains { $0.email.caseInsensitiveCompare(email) == .orderedSame } }
            .map { known[$0.lowercased()] ?? CalendarAttendee(email: $0) }
        if let reminders = draft.reminders { event.reminders = reminders }
        event.meetingURL = draft.meetingURL
        event.transparency = draft.transparency
        event.taskID = draft.taskID
    }

    /// Conflicts of every occurrence of `event` within the busy horizon, without its own copies.
    func conflicts(for event: CalendarEvent, excluding: UUID?) async throws -> [CalendarConflict] {
        let collections = try await store.collections()
        let scope = CalendarNeighbours.of(event.collectionID, in: collections).union([event.collectionID])
        let start = min(CalendarRecurrenceExpander.start(of: event.time), now())
        let window = DateInterval(start: start.addingTimeInterval(-86400), end: now().addingTimeInterval(BusyEngine.horizon))
        let mine = CalendarRecurrenceExpander.occurrences(of: event, overrides: [], in: window).prefix(200)
        let events = try await store.events(collectionIDs: scope, from: window.start, to: window.end, includeCopies: true)
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let occurrences = CalendarExpansion.occurrences(events, in: window)
        var found: [String: CalendarConflict] = [:]
        for occurrence in mine {
            for conflict in CalendarConflictFinder.conflicts(
                start: occurrence.start, end: occurrence.end, collectionID: event.collectionID, excluding: excluding ?? event.id,
                occurrences: occurrences, events: byID, collections: collections)
            {
                let source = byID[conflict.eventID]?.busyMarker?.sourceEventID
                if source == event.id || (excluding != nil && source == excluding) { continue }
                found[conflict.id] = conflict
            }
        }
        return found.values.sorted { $0.start < $1.start }
    }

    enum Undo { case delete, restore(CalendarEvent) }

    /// Writes a changed event: locally at once, to its server through an attempt.
    func writeExisting(
        _ changed: CalendarEvent, previous: CalendarEvent, account: CalendarAccount, collection: CalendarCollection
    )
        async throws -> CalendarWriteOutcome
    {
        let saved = try await store.update(changed, expectedRevision: previous.revision, actor: .user)
        guard account.kind != .local else {
            reconcileSoon()
            return .saved(saved)
        }
        guard let externalID = previous.externalID else { throw CalendarFailure.invalidInput("attempt open") }
        return try await push(.updateEvent, event: saved, account: account, collection: collection, undo: .restore(previous)) { adapter in
            try await adapter.update(
                saved, ref: RemoteEventRef(externalID: externalID, etag: previous.etag), in: collection,
                notify: !saved.attendees.isEmpty)
        }
    }

    func begin(
        _ kind: CalendarAttemptKind, eventID: UUID, collectionID: UUID, payload: CalendarAttemptPayload
    ) async throws -> CalendarAttempt {
        try await store.beginAttempt(
            kind: kind, eventID: eventID, copyID: nil, collectionID: collectionID, payload: try JSONEncoder().encode(payload))
    }

    func push(
        _ kind: CalendarAttemptKind, event: CalendarEvent, account: CalendarAccount, collection: CalendarCollection, undo: Undo,
        _ write: (any CalendarAdapter) async throws -> RemoteEventRef
    ) async throws -> CalendarWriteOutcome {
        let attempt = try await begin(kind, eventID: event.id, collectionID: collection.id, payload: .init(uid: event.uid))
        do {
            let adapter = try await adapter(for: account)
            try await store.markSent(attempt.id)
            let ref = try await write(adapter)
            try await store.settle(attempt.id, state: .confirmed, failure: nil)
            var confirmed = try await store.event(id: event.id) ?? event
            confirmed.externalID = ref.externalID
            confirmed.etag = ref.etag
            let saved = try await store.update(confirmed, expectedRevision: confirmed.revision, actor: .engine)
            reconcileSoon()
            return .saved(saved)
        } catch {
            let state = try await fail(attempt, error: error, accountID: account.id)
            if state == .unknown {
                reconcileSoon()
                return .attemptOpen(try await store.attempt(id: attempt.id) ?? attempt)
            }
            if let current = try await store.event(id: event.id) {
                switch undo {
                case .delete: try await store.markDeleted(id: event.id, expectedRevision: current.revision, actor: .engine)
                case .restore(let previous):
                    var back = previous
                    back.revision = current.revision
                    _ = try await store.update(back, expectedRevision: current.revision, actor: .engine)
                }
            }
            throw Self.surface(error)
        }
    }

    /// Settles a failed attempt: unknown for transport doubt, rejected otherwise; updates the account.
    @discardableResult func fail(_ attempt: CalendarAttempt, error: Error, accountID: UUID) async throws -> CalendarAttemptState {
        let failure: CalendarFailure
        let state: CalendarAttemptState
        switch error {
        case let http as CalendarHTTPError:
            failure = http.failure
            state = .unknown
        case CalendarFailure.unknownOutcome(let stage):
            failure = .unknownOutcome(stage: stage)
            state = .unknown
        case let known as CalendarFailure:
            failure = known
            state = .rejected
        default:
            failure = .unknownOutcome(stage: "write")
            state = .unknown
        }
        try await store.settle(attempt.id, state: state, failure: failure)
        if Self.state(after: failure) == .needsSignIn || failure == .adminBlocked, var account = try? await account(accountID) {
            account.state = Self.state(after: failure)
            account.lastError = failure
            try await store.saveAccount(account)
            adapters[accountID] = nil
        }
        return state
    }

    static func surface(_ error: Error) -> Error { (error as? CalendarHTTPError)?.failure ?? error }
}
