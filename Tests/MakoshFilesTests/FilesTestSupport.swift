import CPostgres
import Foundation
import XCTest
@testable import MakoshCore

/// A generated `makosh_test_` schema in the explicitly supplied database;
/// a missing configuration fails the test instead of passing it.
struct FilesTestDatabase {
    let connectionString: String
    let schema: String

    init() throws {
        guard let value = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !value.isEmpty else {
            throw FilesTestError.configuration("MAKOSH_TEST_DATABASE_URL is required for PostgreSQL integration tests.")
        }
        connectionString = value
        schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    func cleanup() throws {
        guard schema.hasPrefix("makosh_test_"), schema.utf8.count == 44 else {
            throw FilesTestError.configuration("Refusing cleanup outside a generated test schema.")
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
        guard let db else { throw FilesTestError.database }
        defer { PQfinish(db) }
        guard PQstatus(db) == CONNECTION_OK else { throw FilesTestError.database }
        PQsetNoticeProcessor(db, { _, _ in }, nil)
        func command(_ sql: String) throws -> [[String]] {
            guard let result = PQexec(db, sql) else { throw FilesTestError.database }
            defer { PQclear(result) }
            guard PQresultStatus(result) == PGRES_COMMAND_OK || PQresultStatus(result) == PGRES_TUPLES_OK else {
                throw FilesTestError.database
            }
            return (0..<PQntuples(result)).map { row in
                (0..<PQnfields(result)).map { column in PQgetvalue(result, row, column).map { String(cString: $0) } ?? "" }
            }
        }
        _ = try command("SET statement_timeout TO '15s'")
        return try command(sql)
    }
}

enum FilesTestError: Error { case configuration(String), database }

let filesTestKey = Data(repeating: 0x42, count: 32)

extension XCTestCase {
    func filesDatabase() throws -> FilesTestDatabase {
        let database = try FilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        return database
    }
    func archiveStore(_ db: FilesTestDatabase) throws -> MessageArchiveStore {
        try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { _, _ in filesTestKey }
    }
    /// Appends a stored receipt with synthetic hashes; the catalogue reads metadata only.
    @discardableResult func storedFile(
        _ store: MessageArchiveStore, service: String = "telegram", account: String = "a", chat: String = "c", message: String,
        attachment: String, name: String, kind: String = "document", capturedAt: TimeInterval = 30
    ) throws -> ArchiveFileRecord {
        let id = UUID(), vault = try store.fileVault()
        let hash = String(repeating: "ab", count: 32)
        let receipt = ArchiveFileEnvelopeReceipt(byteCount: 2048, sha256: hash, plaintextByteCount: 1024, plaintextSHA256: hash)
        let record = ArchiveFileRecord(
            id: id, identity: .init(service: service, accountID: account, conversationID: chat, messageID: message),
            attachment: .init(id: attachment, kind: kind, name: name, size: 1024),
            objectKey: "vaults/\(vault.id.uuidString.lowercased())/files/\(id.uuidString.lowercased())", storageID: hash,
            receipt: receipt, capturedAt: Date(timeIntervalSince1970: capturedAt), state: .stored,
            purpose: .conversation(defaultEnabled: true))
        _ = try store.appendFile(record)
        return record
    }
}
