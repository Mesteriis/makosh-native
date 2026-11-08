import CryptoKit
import Foundation
import MakoshCore

/// The section's PostgreSQL store: one connection confined to the actor.
/// Private event fields are sealed with a key derived from the archive vault.
public actor CalendarStore {
    private let connectionString: String
    let schema: String
    private let keyProvider: @Sendable (UUID, Bool) throws -> Data
    private var connection: PostgresConnection?
    private var transactionDepth = 0
    var key: SymmetricKey?
    var vault: UUID?
    let now: @Sendable () -> Date
    let encoder = CalendarStore.makeEncoder()
    let decoder = CalendarStore.makeDecoder()

    public init(
        connectionString: String, schema: String,
        keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connectionString = connectionString
        self.schema = schema
        self.keyProvider = keyProvider
        self.now = now
    }

    public func open() throws {
        guard PostgresConnection.isValidSchemaName(schema) else { throw CalendarFailure.invalidSchema }
        if connection?.isOpen != true {
            connection = try wrap { try PostgresConnection(connectionString: connectionString) }
        }
        let (vault, created) = try transaction { () -> (UUID, Bool) in
            try execute("SELECT pg_advisory_xact_lock(hashtext('makosh-calendar-schema'), hashtext($1))", [schema])
            for statement in CalendarStoreSchema.statements(schema: schema) { try execute(statement) }
            if let row = try query("SELECT vault FROM \(t("calendar_metadata")) WHERE id = 1").first, let id = UUID(uuidString: row[0]) {
                return (id, false)
            }
            guard try query("SELECT 1 FROM \(t("calendar_events")) LIMIT 1").isEmpty else { throw CalendarFailure.keyUnavailable }
            let id = UUID()
            try execute("INSERT INTO \(t("calendar_metadata"))(id, version, vault) VALUES (1, 1, $1)", [id.uuidString])
            return (id, true)
        }
        let material: Data
        do { material = try keyProvider(vault, created) } catch { throw CalendarFailure.keyUnavailable }
        guard material.count >= 32 else { throw CalendarFailure.keyUnavailable }
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material), info: Data("makosh-calendar-events-v1".utf8), outputByteCount: 32)
        self.vault = vault
        try settleInterruptedAttempts()
    }

    public func close() {
        connection?.close()
        connection = nil
        key = nil
    }

    // MARK: Accounts, calendars, groups

    public func accounts() throws -> [CalendarAccount] {
        try query("SELECT data FROM \(t("calendar_accounts")) ORDER BY data->>'name', id").map { try decode(CalendarAccount.self, $0[0]) }
    }

    public func saveAccount(_ account: CalendarAccount) throws {
        try execute(
            "INSERT INTO \(t("calendar_accounts"))(id, data) VALUES ($1, $2::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data",
            [account.id.uuidString, try encode(account)])
    }

    /// Disconnects an account: it stays as `disabled`, its calendars hidden, its events kept.
    public func removeAccount(id: UUID) throws {
        try transaction {
            guard var account = try accounts().first(where: { $0.id == id }) else { throw CalendarFailure.notFound }
            account.state = .disabled
            try saveAccount(account)
            for var collection in try collections() where collection.accountID == id {
                collection.shown = false
                try saveCollection(collection)
            }
        }
    }

    public func collections() throws -> [CalendarCollection] {
        try query("SELECT data FROM \(t("calendar_collections")) ORDER BY data->>'name', id").map {
            try decode(CalendarCollection.self, $0[0])
        }
    }

    public func saveCollection(_ collection: CalendarCollection) throws {
        try execute(
            """
            INSERT INTO \(t("calendar_collections"))(id, account_id, data) VALUES ($1, $2, $3::jsonb)
            ON CONFLICT (id) DO UPDATE SET account_id = EXCLUDED.account_id, data = EXCLUDED.data
            """, [collection.id.uuidString, collection.accountID.uuidString, try encode(collection)])
    }

    public func groups() throws -> [CalendarGroup] {
        try query("SELECT data FROM \(t("calendar_groups")) ORDER BY data->>'name', id").map { try decode(CalendarGroup.self, $0[0]) }
    }

    public func saveGroup(_ group: CalendarGroup) throws {
        try execute(
            "INSERT INTO \(t("calendar_groups"))(id, data) VALUES ($1, $2::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data",
            [group.id.uuidString, try encode(group)])
    }

    /// Removes a group and takes it off every calendar in the same transaction.
    public func removeGroup(id: UUID) throws {
        try transaction {
            for var collection in try collections() where collection.groupIDs.contains(id) {
                collection.groupIDs.remove(id)
                try saveCollection(collection)
            }
            try execute("DELETE FROM \(t("calendar_groups")) WHERE id = $1", [id.uuidString])
        }
    }

    /// The one local account «Makosh» with its calendar «Личный», created on first use.
    public func localAccount() throws -> (CalendarAccount, CalendarCollection) {
        try transaction {
            try execute("SELECT pg_advisory_xact_lock(hashtext('makosh-calendar-local'), hashtext($1))", [schema])
            if let account = try accounts().first(where: { $0.kind == .local }),
                let collection = try collections().first(where: { $0.accountID == account.id })
            {
                return (account, collection)
            }
            let account = try accounts().first(where: { $0.kind == .local }) ?? CalendarAccount(kind: .local, name: "Makosh")
            try saveAccount(account)
            let collection = CalendarCollection(accountID: account.id, externalID: "local", name: "Личный", access: .write)
            try saveCollection(collection)
            return (account, collection)
        }
    }

    // MARK: Plumbing

    func t(_ table: String) -> String { "\"\(schema)\".\(table)" }

    @discardableResult func query(_ sql: String, _ parameters: [String?] = []) throws -> [[String]] {
        guard let connection else { throw CalendarFailure.notOpen }
        return try wrap { try connection.query(sql, parameters) }
    }

    func execute(_ sql: String, _ parameters: [String?] = []) throws { _ = try query(sql, parameters) }

    /// One BEGIN/COMMIT for the outermost call; nested calls join it.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard let connection else { throw CalendarFailure.notOpen }
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
    public func performInTransaction<T: Sendable>(_ body: @Sendable (isolated CalendarStore) throws -> T) throws -> T {
        try transaction { try body(self) }
    }

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as PostgresConnection.Failure {
            throw CalendarFailure.storage(failure.sqlState)
        }
    }

    func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        do { return try decoder.decode(type, from: Data(text.utf8)) } catch { throw CalendarFailure.storage("decode") }
    }

    static func makeEncoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CalendarStore.iso(date))
        }
        value.outputFormatting = [.sortedKeys]
        return value
    }

    static func makeDecoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = CalendarStore.date(text) else {
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
        // PostgreSQL prints "2026-11-07 10:00:00.123+00"; normalise to ISO 8601.
        var value = text.replacingOccurrences(of: " ", with: "T")
        if let sign = value.lastIndex(where: { $0 == "+" || $0 == "-" }), value.distance(from: sign, to: value.endIndex) == 3 {
            value += ":00"
        }
        return formatter(fractional: true).date(from: value) ?? formatter(fractional: false).date(from: value)
    }

    /// Placeholder until the attempt journal (task 8) settles `sent` attempts on open.
    func settleInterruptedAttempts() throws {}
}
