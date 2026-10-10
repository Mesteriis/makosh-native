import Foundation
import CPostgres
@testable import MakoshCore

/// Every test receives a unique, generated schema in an explicitly supplied database.
/// Missing PostgreSQL configuration fails the test instead of treating it as a pass.
struct PostgresTestDatabase {
    let connectionString: String
    let schema: String
    var table: String { "\"\(schema)\".state" }

    init() throws {
        guard let value = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !value.isEmpty else {
            throw StoreError.invalid("MAKOSH_TEST_DATABASE_URL is required for PostgreSQL integration tests.")
        }
        connectionString = value
        schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        _ = try makeStore()
    }
    func makeStore() throws -> ContactStore {
        try ContactStore(connectionString: connectionString, schema: schema)
    }
    func cleanup() throws {
        guard schema.hasPrefix("makosh_test_"), schema.utf8.count == 44,
              schema.dropFirst(12).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StoreError.invalid("Refusing cleanup outside a generated test schema.")
        }
        try execute("DROP SCHEMA \"\(schema)\" CASCADE")
    }
    @discardableResult
    func execute(_ sql: String) throws -> [[String]] {
        let db: OpaquePointer? = connectionString.withCString { dsn in
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
        guard let db else { throw StoreError.database("Test PostgreSQL connection failed.") }
        defer { PQfinish(db) }
        guard PQstatus(db) == CONNECTION_OK else { throw StoreError.database("Test PostgreSQL connection failed.") }
        PQsetNoticeProcessor(db, { _, _ in }, nil)
        func command(_ sql: String) throws -> [[String]] {
            guard let result = PQexec(db, sql) else { throw StoreError.database("Test PostgreSQL operation failed.") }
            defer { PQclear(result) }
            guard PQresultStatus(result) == PGRES_COMMAND_OK || PQresultStatus(result) == PGRES_TUPLES_OK else {
                throw StoreError.database("Test PostgreSQL operation failed.")
            }
            return (0..<PQntuples(result)).map { row in
                (0..<PQnfields(result)).map { column in
                    PQgetvalue(result, row, column).map { String(cString: $0) } ?? ""
                }
            }
        }
        _ = try command("SET statement_timeout TO '15s'")
        _ = try command("SET search_path TO \"\(schema)\"")
        return try command(sql)
    }
}
