import Foundation
import MakoshCore

/// The module's PostgreSQL store: settings, sketch links, runs, attempts and installs.
/// One connection confined to the actor; every method is one transaction under the module's advisory lock.
public actor OSINTStore {
    private let connectionString: String
    let schema: String
    private var connection: PostgresConnection?
    private var transactionDepth = 0
    let now: @Sendable () -> Date
    let encoder = OSINTStore.makeEncoder()
    let decoder = OSINTStore.makeDecoder()

    public init(connectionString: String, schema: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.connectionString = connectionString
        self.schema = schema
        self.now = now
    }

    public func open() throws {
        guard PostgresConnection.isValidSchemaName(schema) else { throw OSINTFailure.storage("schema") }
        if connection?.isOpen != true {
            connection = try wrap { try PostgresConnection(connectionString: connectionString) }
        }
        try transaction {
            try execute("SELECT pg_advisory_xact_lock(hashtext('makosh-osint-schema'), hashtext($1))", [schema])
            for statement in OSINTStoreSchema.statements(schema: schema) { try execute(statement) }
            try execute(
                "INSERT INTO \(t("persons_osint_meta"))(id, version) VALUES (1, $1::integer) ON CONFLICT (id) DO NOTHING",
                [String(OSINTStoreSchema.version)])
            guard let text = try query("SELECT version::text FROM \(t("persons_osint_meta")) WHERE id = 1").first?[0],
                let version = Int(text), version == OSINTStoreSchema.version
            else { throw OSINTFailure.storage("version") }
        }
    }

    public func close() {
        connection?.close()
        connection = nil
    }

    // MARK: Settings

    /// The settings row is created on first read so the server id stays the same afterwards.
    public func settings() throws -> OSINTSettings {
        try transaction {
            try lock()
            if let text = try query("SELECT data FROM \(t("persons_osint_settings")) WHERE id = 1").first?[0] {
                return try decode(OSINTSettings.self, text)
            }
            let fresh = OSINTSettings()
            try writeSettings(fresh)
            return fresh
        }
    }

    public func saveSettings(_ settings: OSINTSettings) throws {
        try transaction {
            try lock()
            try writeSettings(settings)
        }
    }

    private func writeSettings(_ settings: OSINTSettings) throws {
        try execute(
            "INSERT INTO \(t("persons_osint_settings"))(id, data) VALUES (1, $1::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data",
            [try encode(settings)])
    }

    // MARK: Sketches

    public func sketch(personID: UUID) throws -> OSINTSketchLink? {
        try query("SELECT data FROM \(t("persons_osint_sketches")) WHERE person_id = $1", [personID.uuidString]).first.map {
            try decode(OSINTSketchLink.self, $0[0])
        }
    }

    /// Forgets every sketch link (a server change): the attempts journal is untouched.
    public func removeAllSketches() throws {
        _ = try execute("DELETE FROM \(t("persons_osint_sketches"))")
    }

    public func sketches() throws -> [OSINTSketchLink] {
        try query("SELECT data FROM \(t("persons_osint_sketches")) ORDER BY data->>'createdAt', person_id").map {
            try decode(OSINTSketchLink.self, $0[0])
        }
    }

    public func saveSketch(_ link: OSINTSketchLink) throws {
        try transaction {
            try lock()
            try execute(
                """
                INSERT INTO \(t("persons_osint_sketches"))(person_id, data) VALUES ($1, $2::jsonb)
                ON CONFLICT (person_id) DO UPDATE SET data = EXCLUDED.data
                """, [link.personID.uuidString, try encode(link)])
        }
    }

    // MARK: Runs

    public func runs(open: Bool) throws -> [OSINTRun] {
        let filter = open ? "WHERE state IN ('queued', 'running', 'unknown')" : ""
        return try query("SELECT data FROM \(t("persons_osint_runs")) \(filter) ORDER BY created_at, id").map {
            try decode(OSINTRun.self, $0[0])
        }
    }

    public func run(id: UUID) throws -> OSINTRun? {
        try query("SELECT data FROM \(t("persons_osint_runs")) WHERE id = $1", [id.uuidString]).first.map {
            try decode(OSINTRun.self, $0[0])
        }
    }

    public func lastRun(personID: UUID) throws -> OSINTRun? {
        try query(
            "SELECT data FROM \(t("persons_osint_runs")) WHERE person_id = $1 ORDER BY created_at DESC, id DESC LIMIT 1",
            [personID.uuidString]
        ).first.map { try decode(OSINTRun.self, $0[0]) }
    }

    public func saveRun(_ run: OSINTRun) throws {
        try transaction {
            try lock()
            try writeRun(run)
        }
    }

    private func writeRun(_ run: OSINTRun) throws {
        try execute(
            """
            INSERT INTO \(t("persons_osint_runs"))(id, person_id, state, created_at, data) VALUES ($1, $2, $3, $4::timestamptz, $5::jsonb)
            ON CONFLICT (id) DO UPDATE SET state = EXCLUDED.state, data = EXCLUDED.data
            """, [run.id.uuidString, run.personID.uuidString, run.state.rawValue, Self.iso(run.createdAt), try encode(run)])
    }

    /// Automatic (book-triggered) runs created at or after `since`.
    public func automaticRunCount(since: Date) throws -> Int {
        let text = try query(
            "SELECT count(*)::text FROM \(t("persons_osint_runs")) WHERE created_at >= $1::timestamptz AND data->'trigger' ? 'book'",
            [Self.iso(since)]
        ).first?[0]
        return Int(text ?? "0") ?? 0
    }

    // MARK: Attempts

    public func attempts(open: Bool) throws -> [OSINTAttempt] {
        let filter = open ? "WHERE state IN ('queued', 'sent', 'unknown')" : ""
        return try query("SELECT data FROM \(t("persons_osint_attempts")) \(filter) ORDER BY created_at, id").map {
            try decode(OSINTAttempt.self, $0[0])
        }
    }

    public func attempts(runID: UUID) throws -> [OSINTAttempt] {
        try query("SELECT data FROM \(t("persons_osint_attempts")) WHERE run_id = $1 ORDER BY created_at, id", [runID.uuidString]).map {
            try decode(OSINTAttempt.self, $0[0])
        }
    }

    public func attempt(id: UUID) throws -> OSINTAttempt? {
        try query("SELECT data FROM \(t("persons_osint_attempts")) WHERE id = $1", [id.uuidString]).first.map {
            try decode(OSINTAttempt.self, $0[0])
        }
    }

    /// Inserts a new attempt (always `queued`) or moves an existing one along the allowed transitions.
    public func saveAttempt(_ attempt: OSINTAttempt) throws {
        try transaction {
            try lock()
            var value = attempt
            if let existing = try self.attempt(id: attempt.id) {
                if existing.state != attempt.state {
                    guard OSINTAttempt.allows(existing.state, attempt.state) else { throw OSINTFailure.storage("attempt transition") }
                    value.updatedAt = now()
                    if attempt.state == .confirmed || attempt.state == .rejected { value.resolvedAt = now() }
                }
            } else {
                guard attempt.state == .queued else { throw OSINTFailure.storage("attempt transition") }
            }
            try writeAttempt(value)
        }
    }

    private func writeAttempt(_ attempt: OSINTAttempt) throws {
        try execute(
            """
            INSERT INTO \(t("persons_osint_attempts"))(id, run_id, state, created_at, data) VALUES ($1, $2, $3, $4::timestamptz, $5::jsonb)
            ON CONFLICT (id) DO UPDATE SET state = EXCLUDED.state, data = EXCLUDED.data
            """,
            [attempt.id.uuidString, attempt.runID?.uuidString, attempt.state.rawValue, Self.iso(attempt.createdAt), try encode(attempt)])
    }

    /// A write that was in flight when the process ended has an unknown outcome now; so does its run.
    public func markSentAsUnknownOnOpen() throws {
        try transaction {
            try lock()
            for var attempt in try attempts(open: true) where attempt.state == .sent {
                attempt.state = .unknown
                attempt.failure = .unknownOutcome(stage: "restart")
                attempt.updatedAt = now()
                try writeAttempt(attempt)
            }
            for var run in try runs(open: true) where run.state == .running {
                run.state = .unknown
                run.failure = .unknownOutcome(stage: "restart")
                try writeRun(run)
            }
        }
    }

    // MARK: Installs

    public func installs() throws -> [OSINTInstall] {
        try query("SELECT data FROM \(t("persons_osint_installs")) ORDER BY created_at, id").map { try decode(OSINTInstall.self, $0[0]) }
    }

    public func saveInstall(_ install: OSINTInstall) throws {
        try transaction {
            try lock()
            try execute(
                """
                INSERT INTO \(t("persons_osint_installs"))(id, created_at, data) VALUES ($1, $2::timestamptz, $3::jsonb)
                ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data
                """, [install.id.uuidString, Self.iso(install.createdAt), try encode(install)])
        }
    }

    // MARK: Plumbing

    func t(_ table: String) -> String { "\"\(schema)\".\(table)" }

    func lock() throws { try execute("SELECT pg_advisory_xact_lock(hashtext('makosh-osint'), hashtext($1))", [schema]) }

    @discardableResult func query(_ sql: String, _ parameters: [String?] = []) throws -> [[String]] {
        guard let connection else { throw OSINTFailure.storage("not open") }
        return try wrap { try connection.query(sql, parameters) }
    }

    func execute(_ sql: String, _ parameters: [String?] = []) throws { _ = try query(sql, parameters) }

    /// One BEGIN/COMMIT for the outermost call; nested calls join it.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard let connection else { throw OSINTFailure.storage("not open") }
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        transactionDepth = 1
        defer { transactionDepth = 0 }
        return try wrap { try connection.transaction(body) }
    }

    /// Several store calls as one transaction; the closure runs on the actor.
    public func performInTransaction<T: Sendable>(_ body: @Sendable (isolated OSINTStore) throws -> T) throws -> T {
        try transaction {
            try lock()
            return try body(self)
        }
    }

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as PostgresConnection.Failure { throw OSINTFailure.storage(failure.sqlState) }
    }

    func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        do { return try decoder.decode(type, from: Data(text.utf8)) } catch { throw OSINTFailure.storage("decode") }
    }

    static func makeEncoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(OSINTStore.iso(date))
        }
        value.outputFormatting = [.sortedKeys]
        return value
    }

    static func makeDecoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = OSINTStore.date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date"))
            }
            return date
        }
        return value
    }

    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let value = ISO8601DateFormatter()
        value.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return value
    }
    static func iso(_ date: Date) -> String { formatter(fractional: true).string(from: date) }
    static func date(_ text: String) -> Date? {
        formatter(fractional: true).date(from: text) ?? formatter(fractional: false).date(from: text)
    }
}
