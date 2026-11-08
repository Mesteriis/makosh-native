import Foundation
import MakoshCore

/// The section's PostgreSQL store: books, card entries, write attempts, collection
/// cursors and preferences. One connection confined to the actor; every method is one
/// transaction under the section's advisory lock.
public actor PersonsStore {
    private let connectionString: String
    let schema: String
    private var connection: PostgresConnection?
    private var transactionDepth = 0
    let now: @Sendable () -> Date
    let encoder = PersonsStore.makeEncoder()
    let decoder = PersonsStore.makeDecoder()

    public init(connectionString: String, schema: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.connectionString = connectionString
        self.schema = schema
        self.now = now
    }

    public func open() throws {
        guard PostgresConnection.isValidSchemaName(schema) else { throw PersonsFailure.invalidSchema }
        if connection?.isOpen != true {
            connection = try wrap { try PostgresConnection(connectionString: connectionString) }
        }
        try transaction {
            try execute("SELECT pg_advisory_xact_lock(hashtext('makosh-persons-schema'), hashtext($1))", [schema])
            for statement in PersonsStoreSchema.statements(schema: schema) { try execute(statement) }
            try execute(
                "INSERT INTO \(t("persons_meta"))(id, version) VALUES (1, $1::integer) ON CONFLICT (id) DO NOTHING",
                [String(PersonsStoreSchema.version)])
            guard let text = try query("SELECT version::text FROM \(t("persons_meta")) WHERE id = 1").first?[0], let version = Int(text),
                version == PersonsStoreSchema.version
            else { throw PersonsFailure.invalidSchema }
            // A write that was in flight when the process ended has an unknown outcome now.
            for var attempt in try attempts(open: true) where attempt.state == .sent {
                attempt.state = .unknown
                attempt.failure = .unknownOutcome(stage: "restart")
                attempt.updatedAt = now()
                try write(attempt)
            }
        }
    }

    public func close() {
        connection?.close()
        connection = nil
    }

    // MARK: Books

    public func books() throws -> [PersonBook] {
        try query("SELECT data FROM \(t("persons_books")) ORDER BY data->>'name', id").map { try decode(PersonBook.self, $0[0]) }
    }

    public func book(id: UUID) throws -> PersonBook? {
        try query("SELECT data FROM \(t("persons_books")) WHERE id = $1", [id.uuidString]).first.map { try decode(PersonBook.self, $0[0]) }
    }

    public func saveBook(_ book: PersonBook) throws {
        try transaction {
            try lock()
            try execute(
                "INSERT INTO \(t("persons_books"))(id, data) VALUES ($1, $2::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data",
                [book.id.uuidString, try encode(book)])
        }
    }

    /// Removes the account row; its entries become `notManaged`, its attempts stay as history.
    public func removeBook(id: UUID) throws {
        try transaction {
            try lock()
            for var entry in try entries(bookID: id) where entry.state == .managed || entry.state == .duplicate {
                entry.state = .notManaged
                entry.updatedAt = now()
                try write(entry)
            }
            try execute("DELETE FROM \(t("persons_books")) WHERE id = $1", [id.uuidString])
        }
    }

    // MARK: Entries

    public func entries(personID: UUID) throws -> [PersonBookEntry] {
        try query("SELECT data FROM \(t("persons_book_entries")) WHERE person_id = $1 ORDER BY external_id, id", [personID.uuidString]).map
        {
            try decode(PersonBookEntry.self, $0[0])
        }
    }

    public func entries(bookID: UUID) throws -> [PersonBookEntry] {
        try query("SELECT data FROM \(t("persons_book_entries")) WHERE book_id = $1 ORDER BY external_id, id", [bookID.uuidString]).map {
            try decode(PersonBookEntry.self, $0[0])
        }
    }

    public func allEntries() throws -> [PersonBookEntry] {
        try query("SELECT data FROM \(t("persons_book_entries")) ORDER BY book_id, external_id, id").map {
            try decode(PersonBookEntry.self, $0[0])
        }
    }

    public func entry(id: UUID) throws -> PersonBookEntry? {
        try query("SELECT data FROM \(t("persons_book_entries")) WHERE id = $1", [id.uuidString]).first.map {
            try decode(PersonBookEntry.self, $0[0])
        }
    }

    public func entry(bookID: UUID, externalID: String) throws -> PersonBookEntry? {
        try query(
            "SELECT data FROM \(t("persons_book_entries")) WHERE book_id = $1 AND external_id = $2", [bookID.uuidString, externalID]
        ).first.map { try decode(PersonBookEntry.self, $0[0]) }
    }

    /// One external card belongs to one person; one person has one managed card per book.
    public func saveEntry(_ entry: PersonBookEntry) throws {
        try transaction {
            try lock()
            if let existing = try self.entry(bookID: entry.bookID, externalID: entry.externalID), existing.id != entry.id {
                throw PersonsFailure.invalidInput("entry")
            }
            if entry.state == .managed,
                try entries(personID: entry.personID).contains(where: {
                    $0.bookID == entry.bookID && $0.state == .managed && $0.id != entry.id
                })
            {
                throw PersonsFailure.invalidInput("entry")
            }
            try write(entry)
        }
    }

    public func deleteEntry(id: UUID) throws {
        try transaction {
            try lock()
            try execute("DELETE FROM \(t("persons_book_entries")) WHERE id = $1", [id.uuidString])
        }
    }

    private func write(_ entry: PersonBookEntry) throws {
        try execute(
            """
            INSERT INTO \(t("persons_book_entries"))(id, person_id, book_id, external_id, state, data) VALUES ($1, $2, $3, $4, $5, $6::jsonb)
            ON CONFLICT (id) DO UPDATE SET person_id = EXCLUDED.person_id, book_id = EXCLUDED.book_id, external_id = EXCLUDED.external_id,
                state = EXCLUDED.state, data = EXCLUDED.data
            """,
            [
                entry.id.uuidString, entry.personID.uuidString, entry.bookID.uuidString, entry.externalID, entry.state.rawValue,
                try encode(entry),
            ])
    }

    // MARK: Attempts

    public func attempts(open: Bool) throws -> [PersonAttempt] {
        let filter = open ? "WHERE state IN ('queued', 'sent', 'unknown')" : ""
        return try query("SELECT data FROM \(t("persons_attempts")) \(filter) ORDER BY created_at, id").map {
            try decode(PersonAttempt.self, $0[0])
        }
    }

    public func attempts(personID: UUID) throws -> [PersonAttempt] {
        try query("SELECT data FROM \(t("persons_attempts")) WHERE person_id = $1 ORDER BY created_at, id", [personID.uuidString]).map {
            try decode(PersonAttempt.self, $0[0])
        }
    }

    public func attempt(id: UUID) throws -> PersonAttempt? {
        try query("SELECT data FROM \(t("persons_attempts")) WHERE id = $1", [id.uuidString]).first.map {
            try decode(PersonAttempt.self, $0[0])
        }
    }

    /// Inserts a new attempt or moves an existing one along the allowed transitions.
    public func saveAttempt(_ attempt: PersonAttempt) throws {
        try transaction {
            try lock()
            var value = attempt
            if let existing = try self.attempt(id: attempt.id) {
                if existing.state != attempt.state {
                    guard PersonAttemptState.allows(existing.state, attempt.state) else {
                        throw PersonsFailure.invalidInput("attempt transition")
                    }
                    value.updatedAt = now()
                    if attempt.state == .confirmed || attempt.state == .rejected { value.resolvedAt = now() }
                }
            } else {
                guard attempt.state == .queued else { throw PersonsFailure.invalidInput("attempt transition") }
            }
            try write(value)
        }
    }

    private func write(_ attempt: PersonAttempt) throws {
        try execute(
            """
            INSERT INTO \(t("persons_attempts"))(id, person_id, book_id, state, data, created_at) VALUES ($1, $2, $3, $4, $5::jsonb, $6::timestamptz)
            ON CONFLICT (id) DO UPDATE SET state = EXCLUDED.state, data = EXCLUDED.data
            """,
            [
                attempt.id.uuidString, attempt.personID.uuidString, attempt.bookID.uuidString, attempt.state.rawValue, try encode(attempt),
                Self.iso(attempt.createdAt),
            ])
    }

    // MARK: Cursors and preferences

    public func cursor(source: ImportSource, scope: String) throws -> PersonCollectionCursor? {
        try query(
            "SELECT data FROM \(t("persons_cursors")) WHERE source_key = $1 AND scope = $2", [Self.key(source), scope]
        ).first.map { try decode(PersonCollectionCursor.self, $0[0]) }
    }

    public func saveCursor(_ cursor: PersonCollectionCursor) throws {
        try transaction {
            try lock()
            try execute(
                "INSERT INTO \(t("persons_cursors"))(source_key, scope, data) VALUES ($1, $2, $3::jsonb) ON CONFLICT (source_key, scope) DO UPDATE SET data = EXCLUDED.data",
                [Self.key(cursor.source), cursor.scope, try encode(cursor)])
        }
    }

    public func preferences() throws -> PersonsPreferences {
        try query("SELECT data FROM \(t("persons_preferences")) WHERE id = 1").first.map { try decode(PersonsPreferences.self, $0[0]) }
            ?? PersonsPreferences()
    }

    public func savePreferences(_ preferences: PersonsPreferences) throws {
        try transaction {
            try lock()
            try execute(
                "INSERT INTO \(t("persons_preferences"))(id, data) VALUES (1, $1::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data",
                [try encode(preferences)])
        }
    }

    // MARK: Plumbing

    static func key(_ source: ImportSource) -> String {
        [source.service, source.accountID].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }

    func t(_ table: String) -> String { "\"\(schema)\".\(table)" }

    func lock() throws { try execute("SELECT pg_advisory_xact_lock(hashtext('makosh-persons'), hashtext($1))", [schema]) }

    @discardableResult func query(_ sql: String, _ parameters: [String?] = []) throws -> [[String]] {
        guard let connection else { throw PersonsFailure.notOpen }
        return try wrap { try connection.query(sql, parameters) }
    }

    func execute(_ sql: String, _ parameters: [String?] = []) throws { _ = try query(sql, parameters) }

    /// One BEGIN/COMMIT for the outermost call; nested calls join it.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard let connection else { throw PersonsFailure.notOpen }
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
    public func performInTransaction<T: Sendable>(_ body: @Sendable (isolated PersonsStore) throws -> T) throws -> T {
        try transaction {
            try lock()
            return try body(self)
        }
    }

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as PostgresConnection.Failure { throw PersonsFailure.storage(failure.sqlState) }
    }

    func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        do { return try decoder.decode(type, from: Data(text.utf8)) } catch { throw PersonsFailure.storage("decode") }
    }

    static func makeEncoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PersonsStore.iso(date))
        }
        value.outputFormatting = [.sortedKeys]
        return value
    }

    static func makeDecoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = PersonsStore.date(text) else {
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
    /// Milliseconds survive the round trip; a date without a fraction still decodes.
    static func iso(_ date: Date) -> String { formatter(fractional: true).string(from: date) }
    static func date(_ text: String) -> Date? {
        formatter(fractional: true).date(from: text) ?? formatter(fractional: false).date(from: text)
    }
}
