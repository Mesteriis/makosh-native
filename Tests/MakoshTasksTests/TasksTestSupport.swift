import CPostgres
import Foundation
import XCTest
@testable import MakoshTasks

/// A generated `makosh_test_` schema in the explicitly supplied database;
/// a missing configuration fails the test instead of passing it.
struct TasksTestDatabase {
    let connectionString: String
    let schema: String

    init() throws {
        guard let value = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !value.isEmpty else {
            throw TasksTestError.configuration("MAKOSH_TEST_DATABASE_URL is required for PostgreSQL integration tests.")
        }
        connectionString = value
        schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    func cleanup() throws {
        guard schema.hasPrefix("makosh_test_"), schema.utf8.count == 44 else {
            throw TasksTestError.configuration("Refusing cleanup outside a generated test schema.")
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
        guard let db else { throw TasksTestError.database }
        defer { PQfinish(db) }
        guard PQstatus(db) == CONNECTION_OK else { throw TasksTestError.database }
        PQsetNoticeProcessor(db, { _, _ in }, nil)
        func command(_ sql: String) throws -> [[String]] {
            guard let result = PQexec(db, sql) else { throw TasksTestError.database }
            defer { PQclear(result) }
            guard PQresultStatus(result) == PGRES_COMMAND_OK || PQresultStatus(result) == PGRES_TUPLES_OK else {
                throw TasksTestError.database
            }
            return (0..<PQntuples(result)).map { row in
                (0..<PQnfields(result)).map { column in PQgetvalue(result, row, column).map { String(cString: $0) } ?? "" }
            }
        }
        _ = try command("SET statement_timeout TO '15s'")
        return try command(sql)
    }
}

enum TasksTestError: Error { case configuration(String), database }

extension XCTestCase {
    func tasksDatabase() throws -> TasksTestDatabase {
        let database = try TasksTestDatabase()
        addTeardownBlock { try database.cleanup() }
        return database
    }
    func taskStore(_ db: TasksTestDatabase) async throws -> TaskStore {
        let store = TaskStore(connectionString: db.connectionString, schema: db.schema)
        try await store.open()
        return store
    }
}
