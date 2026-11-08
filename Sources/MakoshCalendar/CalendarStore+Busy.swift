import Foundation

extension CalendarStore {
    // MARK: Busy copies

    public func busyCopies(targetCollectionID: UUID?) throws -> [BusyCopyRecord] {
        let rows: [[String]]
        if let targetCollectionID {
            rows = try query(
                "SELECT data FROM \(t("calendar_busy_copies")) WHERE target_collection_id = $1 ORDER BY occurrence_key, id",
                [targetCollectionID.uuidString])
        } else {
            rows = try query("SELECT data FROM \(t("calendar_busy_copies")) ORDER BY occurrence_key, id")
        }
        return try rows.map { try decode(BusyCopyRecord.self, $0[0]) }
    }

    public func saveBusyCopy(_ record: BusyCopyRecord) throws {
        try execute(
            """
            INSERT INTO \(t("calendar_busy_copies"))(id, source_event_id, occurrence_key, target_collection_id, data)
            VALUES ($1, $2, $3, $4, $5::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data
            """,
            [
                record.id.uuidString, record.sourceEventID.uuidString, CalendarStore.iso(record.occurrenceKey),
                record.targetCollectionID.uuidString, try encode(record),
            ])
    }

    public func removeBusyCopy(id: UUID) throws {
        try execute("DELETE FROM \(t("calendar_busy_copies")) WHERE id = $1", [id.uuidString])
    }

    // MARK: Attempts

    public func beginAttempt(
        kind: CalendarAttemptKind, eventID: UUID?, copyID: UUID?, collectionID: UUID, payload: Data
    ) throws
        -> CalendarAttempt
    {
        try transaction {
            try execute("SELECT pg_advisory_xact_lock(hashtext('makosh-calendar-attempts'), hashtext($1))", [schema])
            let open = try query(
                """
                SELECT 1 FROM \(t("calendar_attempts")) WHERE kind = $1 AND collection_id = $2 AND state IN ('queued', 'sent', 'unknown')
                  AND event_id IS NOT DISTINCT FROM $3::uuid AND copy_id IS NOT DISTINCT FROM $4::uuid
                """, [kind.rawValue, collectionID.uuidString, eventID?.uuidString, copyID?.uuidString])
            guard open.isEmpty else { throw CalendarFailure.invalidInput("attempt open") }
            let at = now()
            let attempt = CalendarAttempt(
                id: UUID(), eventID: eventID, copyID: copyID, collectionID: collectionID, kind: kind, state: .queued, payload: payload,
                failure: nil, createdAt: at, updatedAt: at, resolvedAt: nil)
            try execute(
                """
                INSERT INTO \(t("calendar_attempts"))(id, event_id, copy_id, collection_id, kind, state, data, created_at, updated_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $8)
                """,
                [
                    attempt.id.uuidString, eventID?.uuidString, copyID?.uuidString, collectionID.uuidString, kind.rawValue,
                    attempt.state.rawValue, try encode(attempt), CalendarStore.iso(at),
                ])
            return attempt
        }
    }

    public func markSent(_ id: UUID) throws {
        try transition(id, to: .sent, failure: nil, allowed: [.queued])
    }

    /// `queued|sent → confirmed|rejected|unknown`, `unknown → confirmed|rejected`.
    public func settle(_ id: UUID, state: CalendarAttemptState, failure: CalendarFailure?) throws {
        let allowed: Set<CalendarAttemptState>
        switch state {
        case .confirmed, .rejected: allowed = [.queued, .sent, .unknown]
        case .unknown: allowed = [.queued, .sent]
        case .queued, .sent: throw CalendarFailure.invalidInput("attempt transition")
        }
        try transition(id, to: state, failure: failure, allowed: allowed)
    }

    public func attempt(id: UUID) throws -> CalendarAttempt? {
        try query("SELECT data FROM \(t("calendar_attempts")) WHERE id = $1", [id.uuidString]).first.map {
            try decode(CalendarAttempt.self, $0[0])
        }
    }

    public func openAttempts() throws -> [CalendarAttempt] {
        try query(
            "SELECT data FROM \(t("calendar_attempts")) WHERE state IN ('queued', 'sent', 'unknown') ORDER BY created_at, id"
        ).map { try decode(CalendarAttempt.self, $0[0]) }
    }

    public func attempts(eventID: UUID) throws -> [CalendarAttempt] {
        try query("SELECT data FROM \(t("calendar_attempts")) WHERE event_id = $1 ORDER BY created_at, id", [eventID.uuidString]).map {
            try decode(CalendarAttempt.self, $0[0])
        }
    }

    private func transition(
        _ id: UUID, to state: CalendarAttemptState, failure: CalendarFailure?, allowed: Set<CalendarAttemptState>
    ) throws {
        try transaction {
            guard
                var attempt = try query("SELECT data FROM \(t("calendar_attempts")) WHERE id = $1 FOR UPDATE", [id.uuidString]).first.map({
                    try decode(CalendarAttempt.self, $0[0])
                })
            else { throw CalendarFailure.notFound }
            guard allowed.contains(attempt.state) else { throw CalendarFailure.invalidInput("attempt transition") }
            attempt.state = state
            attempt.failure = failure ?? attempt.failure
            attempt.updatedAt = now()
            if state == .confirmed || state == .rejected { attempt.resolvedAt = attempt.updatedAt }
            try execute(
                "UPDATE \(t("calendar_attempts")) SET state = $2, data = $3::jsonb, updated_at = $4, resolved_at = $5 WHERE id = $1",
                [
                    id.uuidString, state.rawValue, try encode(attempt), CalendarStore.iso(attempt.updatedAt),
                    attempt.resolvedAt.map(CalendarStore.iso),
                ])
        }
    }

    /// After a restart nobody knows whether a `sent` write reached the server.
    func settleInterruptedAttempts() throws {
        for attempt in try openAttempts() where attempt.state == .sent {
            try settle(attempt.id, state: .unknown, failure: .unknownOutcome(stage: "restart"))
        }
    }
}
