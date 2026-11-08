import CryptoKit
import Foundation

/// Who changed an event: the user in Makosh, an observation from a server, or the busy engine.
public enum CalendarActor: String, Codable, Sendable {
    case user, remote, engine
}

public struct CalendarEventVersion: Equatable, Sendable {
    public let revision: Int64
    public let actor: CalendarActor
    public let event: CalendarEvent
    public let at: Date
}

/// The fields of an event that stay sealed in PostgreSQL.
struct CalendarSealedFields: Codable {
    var notes: String
    var location: String
    var attendees: [CalendarAttendee]
    var organizerEmail: String?
    var meetingURL: URL?
}

extension CalendarStore {
    static let eventLimit = 1 << 20

    @discardableResult public func insert(_ event: CalendarEvent, actor: CalendarActor) throws -> CalendarEvent {
        try transaction {
            var stored = event
            stored.revision = 1
            stored.updatedAt = now()
            try writeEvent(stored, insert: true)
            try appendVersion(stored, actor: actor)
            return stored
        }
    }

    @discardableResult public func update(_ event: CalendarEvent, expectedRevision: Int64, actor: CalendarActor) throws -> CalendarEvent {
        try transaction {
            guard let current = try revision(of: event.id) else { throw CalendarFailure.notFound }
            guard current == expectedRevision else { throw CalendarFailure.staleRevision }
            var stored = event
            stored.revision = current + 1
            stored.updatedAt = now()
            try writeEvent(stored, insert: false)
            try appendVersion(stored, actor: actor)
            return stored
        }
    }

    public func markDeleted(id: UUID, expectedRevision: Int64, actor: CalendarActor) throws {
        try transaction {
            guard var event = try event(id: id) else { throw CalendarFailure.notFound }
            guard event.revision == expectedRevision else { throw CalendarFailure.staleRevision }
            event.deletedAt = now()
            event.revision += 1
            event.updatedAt = now()
            try writeEvent(event, insert: false)
            try appendVersion(event, actor: actor)
        }
    }

    /// Stores what a server showed: inserts or updates by external id, always
    /// with a new version. A local task link survives an observation without one.
    @discardableResult public func observe(_ remote: CalendarEvent, collectionID: UUID) throws -> CalendarEvent {
        guard let externalID = remote.externalID else { throw CalendarFailure.invalidInput("external id") }
        return try transaction {
            // A row written here before the server confirmed it (unknown outcome) is adopted by UID, never duplicated.
            let existing =
                try query(
                    "SELECT data, sealed FROM \(t("calendar_events")) WHERE collection_id = $1 AND external_id = $2",
                    [collectionID.uuidString, externalID]
                ).first.map { try readEvent(data: $0[0], sealed: $0[1]) }
                ?? query(
                    """
                    SELECT data, sealed FROM \(t("calendar_events")) WHERE collection_id = $1 AND uid = $2 AND external_id IS NULL
                      AND recurrence_id IS NOT DISTINCT FROM $3::timestamptz AND deleted_at IS NULL LIMIT 1
                    """, [collectionID.uuidString, remote.uid, remote.recurrenceID.map(CalendarStore.iso)]
                ).first.map { try readEvent(data: $0[0], sealed: $0[1]) }
            var stored = remote
            if let existing {
                stored = CalendarEvent(
                    id: existing.id, collectionID: collectionID, externalID: externalID, uid: remote.uid, title: remote.title,
                    notes: remote.notes, location: remote.location, time: remote.time, recurrence: remote.recurrence,
                    recurrenceID: remote.recurrenceID, masterID: remote.masterID ?? existing.masterID, attendees: remote.attendees,
                    organizerEmail: remote.organizerEmail, reminders: remote.reminders, meetingURL: remote.meetingURL,
                    transparency: remote.transparency, status: remote.status, taskID: remote.taskID ?? existing.taskID,
                    busyMarker: remote.busyMarker, etag: remote.etag, revision: existing.revision + 1, updatedAt: now(), deletedAt: nil)
                try writeEvent(stored, insert: false)
            } else {
                stored.collectionID = collectionID
                stored.revision = 1
                stored.updatedAt = now()
                stored.deletedAt = nil
                try writeEvent(stored, insert: true)
            }
            try appendVersion(stored, actor: .remote)
            return stored
        }
    }

    /// A server no longer has the event: it is marked deleted, its history stays.
    public func observeRemoval(externalID: String, collectionID: UUID) throws {
        try transaction {
            guard
                let row = try query(
                    "SELECT data, sealed FROM \(t("calendar_events")) WHERE collection_id = $1 AND external_id = $2 AND deleted_at IS NULL",
                    [collectionID.uuidString, externalID]
                ).first
            else { return }
            var event = try readEvent(data: row[0], sealed: row[1])
            event.deletedAt = now()
            event.revision += 1
            event.updatedAt = now()
            try writeEvent(event, insert: false)
            try appendVersion(event, actor: .remote)
        }
    }

    public func event(id: UUID) throws -> CalendarEvent? {
        try query("SELECT data, sealed FROM \(t("calendar_events")) WHERE id = $1", [id.uuidString]).first.map {
            try readEvent(data: $0[0], sealed: $0[1])
        }
    }

    public func event(externalID: String, collectionID: UUID) throws -> CalendarEvent? {
        try query(
            "SELECT data, sealed FROM \(t("calendar_events")) WHERE collection_id = $1 AND external_id = $2",
            [collectionID.uuidString, externalID]
        ).first.map { try readEvent(data: $0[0], sealed: $0[1]) }
    }

    public func events(uid: String, collectionID: UUID) throws -> [CalendarEvent] {
        try query(
            "SELECT data, sealed FROM \(t("calendar_events")) WHERE collection_id = $1 AND uid = $2 AND deleted_at IS NULL",
            [collectionID.uuidString, uid]
        ).map { try readEvent(data: $0[0], sealed: $0[1]) }
    }

    /// Live events of the calendars that may touch the interval: series masters and
    /// overrides always (the caller expands them), single events by overlap.
    public func events(collectionIDs: Set<UUID>, from: Date, to: Date, includeCopies: Bool) throws -> [CalendarEvent] {
        guard !collectionIDs.isEmpty else { return [] }
        let ids = "{" + collectionIDs.map(\.uuidString).joined(separator: ",") + "}"
        return try query(
            """
            SELECT data, sealed FROM \(t("calendar_events"))
            WHERE collection_id = ANY($1::uuid[]) AND deleted_at IS NULL
              AND (recurring OR recurrence_id IS NOT NULL OR (starts_at < $3 AND ends_at > $2))
              AND ($4 OR busy_source IS NULL)
            ORDER BY starts_at, id
            """, [ids, CalendarStore.iso(from), CalendarStore.iso(to), includeCopies ? "true" : "false"]
        ).map { try readEvent(data: $0[0], sealed: $0[1]) }
    }

    public func versions(eventID: UUID) throws -> [CalendarEventVersion] {
        try query(
            "SELECT revision, actor, data, sealed, at FROM \(t("calendar_event_versions")) WHERE event_id = $1 ORDER BY seq",
            [eventID.uuidString]
        ).map { row in
            CalendarEventVersion(
                revision: Int64(row[0]) ?? 0, actor: CalendarActor(rawValue: row[1]) ?? .user,
                event: try readEvent(data: row[2], sealed: row[3]),
                at: CalendarStore.date(row[4]) ?? Date.distantPast)
        }
    }

    // MARK: Cursors

    public func cursor(collectionID: UUID) throws -> Data? {
        try query("SELECT data FROM \(t("calendar_cursors")) WHERE collection_id = $1", [collectionID.uuidString]).first.flatMap {
            Data(base64Encoded: $0[0])
        }
    }

    public func saveCursor(_ data: Data?, collectionID: UUID) throws {
        guard let data else {
            try execute("DELETE FROM \(t("calendar_cursors")) WHERE collection_id = $1", [collectionID.uuidString])
            return
        }
        try execute(
            """
            INSERT INTO \(t("calendar_cursors"))(collection_id, data) VALUES ($1, $2)
            ON CONFLICT (collection_id) DO UPDATE SET data = EXCLUDED.data
            """, [collectionID.uuidString, data.base64EncodedString()])
    }

    // MARK: Rows

    private func revision(of id: UUID) throws -> Int64? {
        try query("SELECT revision FROM \(t("calendar_events")) WHERE id = $1", [id.uuidString]).first.flatMap { Int64($0[0]) }
    }

    private func split(_ event: CalendarEvent) throws -> (data: String, sealed: String) {
        var open = event
        open.notes = ""
        open.location = ""
        open.attendees = []
        open.organizerEmail = nil
        open.meetingURL = nil
        let fields = CalendarSealedFields(
            notes: event.notes, location: event.location, attendees: event.attendees, organizerEmail: event.organizerEmail,
            meetingURL: event.meetingURL)
        let data = try encode(open)
        let sealed = try seal(try encoder.encode(fields), eventID: event.id)
        guard data.utf8.count + sealed.utf8.count <= CalendarStore.eventLimit else { throw CalendarFailure.invalidInput("event too large") }
        return (data, sealed)
    }

    func readEventRow(data: String, sealed: String) throws -> CalendarEvent { try readEvent(data: data, sealed: sealed) }

    private func readEvent(data: String, sealed: String) throws -> CalendarEvent {
        var event = try decode(CalendarEvent.self, data)
        let fields = try decoder.decode(CalendarSealedFields.self, from: try open(sealed, eventID: event.id))
        event.notes = fields.notes
        event.location = fields.location
        event.attendees = fields.attendees
        event.organizerEmail = fields.organizerEmail
        event.meetingURL = fields.meetingURL
        return event
    }

    private func writeEvent(_ event: CalendarEvent, insert: Bool) throws {
        let (data, sealed) = try split(event)
        let occurrence = CalendarOccurrence(eventID: event.id, collectionID: event.collectionID, time: event.time, key: Date())
        let parameters: [String?] = [
            event.id.uuidString, event.collectionID.uuidString, event.uid, event.externalID, event.masterID?.uuidString,
            event.recurrenceID.map(CalendarStore.iso), CalendarStore.iso(occurrence.start), CalendarStore.iso(occurrence.end),
            event.recurrence == nil ? "false" : "true", event.busyMarker?.sourceEventID.uuidString, event.taskID?.uuidString,
            event.deletedAt.map(CalendarStore.iso), String(event.revision), data, sealed,
        ]
        if insert {
            try execute(
                """
                INSERT INTO \(t("calendar_events"))(id, collection_id, uid, external_id, master_id, recurrence_id, starts_at, ends_at,
                    recurring, busy_source, task_id, deleted_at, revision, data, sealed)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14::jsonb, $15)
                """, parameters)
        } else {
            try execute(
                """
                UPDATE \(t("calendar_events")) SET collection_id = $2, uid = $3, external_id = $4, master_id = $5, recurrence_id = $6,
                    starts_at = $7, ends_at = $8, recurring = $9, busy_source = $10, task_id = $11, deleted_at = $12, revision = $13,
                    data = $14::jsonb, sealed = $15
                WHERE id = $1
                """, parameters)
        }
    }

    private func appendVersion(_ event: CalendarEvent, actor: CalendarActor) throws {
        let (data, sealed) = try split(event)
        try execute(
            """
            INSERT INTO \(t("calendar_event_versions"))(event_id, revision, actor, data, sealed, at)
            VALUES ($1, $2, $3, $4::jsonb, $5, $6)
            """, [event.id.uuidString, String(event.revision), actor.rawValue, data, sealed, CalendarStore.iso(now())])
    }

    private func seal(_ plain: Data, eventID: UUID) throws -> String {
        guard let key, let vault else { throw CalendarFailure.keyUnavailable }
        let context = Data((vault.uuidString + "/" + eventID.uuidString).utf8)
        guard let sealed = try? AES.GCM.seal(plain, using: key, authenticating: context).combined else {
            throw CalendarFailure.storage("seal")
        }
        return sealed.base64EncodedString()
    }

    private func open(_ text: String, eventID: UUID) throws -> Data {
        guard let key, let vault, let combined = Data(base64Encoded: text) else { throw CalendarFailure.keyUnavailable }
        let context = Data((vault.uuidString + "/" + eventID.uuidString).utf8)
        do { return try AES.GCM.open(.init(combined: combined), using: key, authenticating: context) } catch {
            throw CalendarFailure.keyUnavailable
        }
    }
}

extension CalendarStore {
    /// Every live event of a calendar, copies included: the full-resync check needs them.
    public func liveEvents(collectionID: UUID) throws -> [CalendarEvent] {
        try query(
            "SELECT data, sealed FROM \(t("calendar_events")) WHERE collection_id = $1 AND deleted_at IS NULL ORDER BY starts_at, id",
            [collectionID.uuidString]
        ).map { try readEventRow(data: $0[0], sealed: $0[1]) }
    }

    /// A removal by a resource URL also removes the overrides stored as `<url>#<recurrence id>`.
    public func observeRemoval(resource externalID: String, collectionID: UUID) throws {
        try transaction {
            let ids = try query(
                """
                SELECT external_id FROM \(t("calendar_events"))
                WHERE collection_id = $1 AND deleted_at IS NULL AND (external_id = $2 OR starts_with(external_id, $2 || '#'))
                """, [collectionID.uuidString, externalID])
            for row in ids { try observeRemoval(externalID: row[0], collectionID: collectionID) }
        }
    }
}
