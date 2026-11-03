import CPostgres
import Foundation

/// A single libpq connection confined to its owning store, worker or actor.
///
/// Every Makosh store shares these rules: a finite connect timeout that a DSN
/// cannot override, suppressed server notices (they can echo imported data),
/// bounded statement/lock timeouts and errors that expose at most a SQLSTATE.
/// The connection is not thread-safe; it is never shared between executors.
public final class PostgresConnection {
    /// A sanitized failure. libpq message text may embed DSNs, credentials or
    /// imported values, so only the standardized five-character code is kept.
    public struct Failure: Error, Equatable, Sendable {
        public let sqlState: String?
    }

    public struct Settings: Sendable {
        public var statementTimeout: String?
        public var lockTimeout: String?
        public var readOnly: Bool
        public init(statementTimeout: String? = "15s", lockTimeout: String? = "5s", readOnly: Bool = false) {
            self.statementTimeout = statementTimeout
            self.lockTimeout = lockTimeout
            self.readOnly = readOnly
        }
    }

    private var handle: OpaquePointer?

    /// Connects immediately and applies `settings`; throws `Failure` without
    /// revealing connection details.
    public init(connectionString: String, settings: Settings = Settings()) throws {
        guard !connectionString.utf8.contains(0) else { throw Failure(sqlState: nil) }
        handle = Self.connect(connectionString)
        guard let handle, PQstatus(handle) == CONNECTION_OK else {
            close()
            throw Failure(sqlState: nil)
        }
        PQsetNoticeProcessor(handle, { _, _ in }, nil)
        do {
            try execute("SET client_encoding TO 'UTF8'")
            if let value = settings.statementTimeout { try execute("SET statement_timeout TO '\(value)'") }
            if let value = settings.lockTimeout { try execute("SET lock_timeout TO '\(value)'") }
            if settings.readOnly { try execute("SET default_transaction_read_only TO on") }
        } catch {
            close()
            throw error
        }
    }

    deinit {
        // Teardown never blocks the releasing executor on network I/O.
        if let handle {
            let owned = ReleasedHandle(value: handle)
            DispatchQueue.global(qos: .utility).async { PQfinish(owned.value) }
        }
    }

    public var isOpen: Bool { handle != nil }

    public func close() {
        if let handle { PQfinish(handle) }
        handle = nil
    }

    /// Runs one statement with text parameters. `nil` binds SQL NULL; NULL
    /// result values are returned as empty strings.
    @discardableResult
    public func query(_ sql: String, _ parameters: [String?] = []) throws -> [[String]] {
        guard let handle, parameters.count <= Int(Int32.max),
            !parameters.contains(where: { $0?.utf8.contains(0) == true })
        else { throw Failure(sqlState: nil) }
        let allocated = parameters.map { $0.flatMap { strdup($0) } }
        defer { allocated.forEach { free($0) } }
        let values = allocated.map { $0.map { UnsafePointer<CChar>($0) } }
        let result = values.withUnsafeBufferPointer {
            PQexecParams(handle, sql, Int32(values.count), nil, $0.baseAddress, nil, nil, 0)
        }
        guard let result else { throw Failure(sqlState: nil) }
        defer { PQclear(result) }
        let status = PQresultStatus(result)
        guard status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK else { throw Failure(sqlState: Self.sqlState(result)) }
        return (0..<PQntuples(result)).map { row in
            (0..<PQnfields(result)).map { column in
                PQgetisnull(result, row, column) == 1 ? "" : String(cString: PQgetvalue(result, row, column))
            }
        }
    }

    public func execute(_ sql: String, _ parameters: [String?] = []) throws {
        _ = try query(sql, parameters)
    }

    /// Runs `body` inside BEGIN/COMMIT and rolls back on any thrown error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    /// Lower-case ASCII identifiers only, so a schema can be quoted into SQL.
    public static func isValidSchemaName(_ schema: String) -> Bool {
        let bytes = Array(schema.utf8)
        return !bytes.isEmpty && bytes.count <= 63 && (97...122).contains(bytes[0])
            && bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    private static func connect(_ connectionString: String) -> OpaquePointer? {
        // The later keyword overrides any timeout in a URI or keyword DSN.
        connectionString.withCString { dsn in
            "dbname".withCString { databaseKey in
                "connect_timeout".withCString { timeoutKey in
                    "5".withCString { timeout in
                        let keys: [UnsafePointer<CChar>?] = [databaseKey, timeoutKey, nil]
                        let values: [UnsafePointer<CChar>?] = [dsn, timeout, nil]
                        return keys.withUnsafeBufferPointer { keys in
                            values.withUnsafeBufferPointer { values in
                                PQconnectdbParams(keys.baseAddress, values.baseAddress, 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func sqlState(_ result: OpaquePointer) -> String? {
        guard let field = PQresultErrorField(result, Int32(MAKOSH_PG_DIAG_SQLSTATE)) else { return nil }
        let code = String(cString: field)
        guard code.utf8.count == 5, code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
        return code
    }
}

/// libpq handles may be finished from any thread once their owner is gone.
private struct ReleasedHandle: @unchecked Sendable { let value: OpaquePointer }
