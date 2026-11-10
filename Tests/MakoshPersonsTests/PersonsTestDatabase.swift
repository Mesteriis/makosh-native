import CPostgres
import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

/// Every test receives a unique, generated schema in the explicitly supplied development database;
/// the core person store and the section's own store open it together, as the application does.
struct PersonsTestDatabase {
    let connectionString: String
    let schema: String

    init() throws {
        guard let value = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !value.isEmpty else {
            throw PersonsTestError.configuration("MAKOSH_TEST_DATABASE_URL is required for PostgreSQL integration tests.")
        }
        connectionString = value
        schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    func persons() throws -> PersonStore { try PersonStore(connectionString: connectionString, schema: schema) }

    func cleanup() throws {
        guard schema.hasPrefix("makosh_test_"), schema.utf8.count == 44 else {
            throw PersonsTestError.configuration("Refusing cleanup outside a generated test schema.")
        }
        try execute("DROP SCHEMA IF EXISTS \"\(schema)\" CASCADE")
    }

    @discardableResult func execute(_ sql: String) throws -> [[String]] {
        let db: OpaquePointer? = connectionString.withCString { dsn in
            "dbname".withCString { databaseKey in
                "connect_timeout".withCString { timeoutKey in
                    "5".withCString { timeout in
                        let keys: [UnsafePointer<CChar>?] = [databaseKey, timeoutKey, nil]
                        let values: [UnsafePointer<CChar>?] = [dsn, timeout, nil]
                        return keys.withUnsafeBufferPointer { keys in
                            values.withUnsafeBufferPointer { values in PQconnectdbParams(keys.baseAddress, values.baseAddress, 1) }
                        }
                    }
                }
            }
        }
        guard let db else { throw PersonsTestError.database }
        defer { PQfinish(db) }
        guard PQstatus(db) == CONNECTION_OK else { throw PersonsTestError.database }
        PQsetNoticeProcessor(db, { _, _ in }, nil)
        func command(_ sql: String) throws -> [[String]] {
            guard let result = PQexec(db, sql) else { throw PersonsTestError.database }
            defer { PQclear(result) }
            guard PQresultStatus(result) == PGRES_COMMAND_OK || PQresultStatus(result) == PGRES_TUPLES_OK else {
                throw PersonsTestError.database
            }
            return (0..<PQntuples(result)).map { row in
                (0..<PQnfields(result)).map { column in PQgetvalue(result, row, column).map { String(cString: $0) } ?? "" }
            }
        }
        _ = try command("SET statement_timeout TO '15s'")
        _ = try command("SET search_path TO \"\(schema)\"")
        return try command(sql)
    }
}

enum PersonsTestError: Error { case configuration(String), database }

extension XCTestCase {
    func personsDatabase() throws -> PersonsTestDatabase {
        let database = try PersonsTestDatabase()
        addTeardownBlock { try database.cleanup() }
        return database
    }
    nonisolated(nonsending) func personsStore(
        _ db: PersonsTestDatabase, now: @escaping @Sendable () -> Date = Date.init
    ) async throws
        -> PersonsStore
    {
        let store = PersonsStore(connectionString: db.connectionString, schema: db.schema, now: now)
        try await store.open()
        // The suite keeps every test case alive until it ends: close now, not when the actor is freed.
        addTeardownBlock { await store.close() }
        return store
    }
}
