import XCTest
import ImageIO
import CoreGraphics
@testable import MakoshTelegram
import Foundation
import CPostgres
import MakoshCore

/// Every test receives a unique, generated schema in an explicitly supplied database.
/// Missing PostgreSQL configuration fails the test instead of treating it as a pass.
struct PendingFilesTestDatabase {
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

final class TelegramPendingUploadFilesTests: XCTestCase {
    @MainActor func testRealEncryptedArchiveRestoresExactFileAndNormalizedPhotoAcrossAdapterRestart() async throws {
        guard let configPath = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw MessageArchiveError.invalid }
        let config = try S3ConfigurationFile.read(URL(fileURLWithPath: configPath))
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: config, spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _, _ in Data(repeating: 0x45, count: 32) })
        for mode: TelegramUploadMode in [.file, .photo] {
            let source = root.appendingPathComponent(mode == .file ? "synthetic.txt" : "synthetic.jpg")
            if mode == .file { try Data("synthetic preserved bytes".utf8).write(to: source) }
            else {
                let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 40, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
                context.setFillColor(gray: 0.4, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
                let image = try XCTUnwrap(context.makeImage())
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            let staged = try await TelegramUploadFileIO.stage(source, mode: mode)
            addTeardownBlock { try TelegramUploadFileIO.discard(staged) }
            let bytes = try Data(contentsOf: staged.url), preparation = UUID()
            let adapter = TelegramPendingUploadFiles(repository: repository)
            let record = try await adapter.save(file: staged, accountID: 1, chatID: 2, preparationID: preparation)
            try TelegramUploadFileIO.discard(staged)
            let restored = try await TelegramPendingUploadFiles(repository: repository).restore(record: record, accountID: 1, chatID: 2, preparationID: preparation)
            addTeardownBlock { try TelegramUploadFileIO.discard(restored) }
            XCTAssertEqual(try Data(contentsOf: restored.url), bytes)
            XCTAssertEqual(restored.name, staged.name); XCTAssertEqual(restored.mode, mode)
            XCTAssertEqual(restored.pixelWidth, staged.pixelWidth); XCTAssertEqual(restored.pixelHeight, staged.pixelHeight)
            for scope in [(Int64(9), Int64(2), preparation), (1, 9, preparation), (1, 2, UUID())] {
                do { _ = try await adapter.restore(record: record, accountID: scope.0, chatID: scope.1, preparationID: scope.2); XCTFail("Foreign scope must fail") } catch {}
            }
            var altered = record
            altered.state = .pending
            do { _ = try await adapter.restore(record: altered, accountID: 1, chatID: 2, preparationID: preparation); XCTFail("Unstored reference must fail") } catch {}
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
            var attachment = try XCTUnwrap(metadata["attachment"] as? [String: Any])
            attachment["name"] = "different.txt"; metadata["attachment"] = attachment
            let forgedRecord = try JSONDecoder().decode(ArchiveFileRecord.self, from: JSONSerialization.data(withJSONObject: metadata))
            do { _ = try await adapter.restore(record: forgedRecord, accountID: 1, chatID: 2, preparationID: preparation); XCTFail("Unauthenticated metadata must fail") } catch {}
            let cancelled = Task { @MainActor in try Task.checkCancellation(); return try await adapter.restore(record: record, accountID: 1, chatID: 2, preparationID: preparation) }
            cancelled.cancel()
            do { let unexpected = try await cancelled.value; try TelegramUploadFileIO.discard(unexpected); XCTFail("Cancellation must fail") } catch {}
            XCTAssertEqual(try Data(contentsOf: restored.url), bytes)
        }
    }

    func testForeignAndMissingStageRejectedBeforeRepositoryAccess() async throws {
        // Owned-stage validation is synchronous and cannot access arbitrary paths.
        let id = UUID(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let foreign = TelegramUploadFile(id: id, name: "foreign", size: 1, mode: .file, pixelWidth: nil, pixelHeight: nil, url: root.appendingPathComponent("unrelated"), directory: root)
        XCTAssertThrowsError(try TelegramUploadFileIO.validateOwnedStage(foreign))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + id.uuidString)
        let absent = TelegramUploadFile(id: id, name: "absent", size: 1, mode: .file, pixelWidth: nil, pixelHeight: nil, url: directory.appendingPathComponent("payload-" + id.uuidString), directory: directory)
        XCTAssertThrowsError(try TelegramUploadFileIO.validateOwnedStage(absent))
    }
}
