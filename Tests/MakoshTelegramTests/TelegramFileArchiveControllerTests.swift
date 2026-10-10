import XCTest
import Foundation
import CPostgres
import MakoshCore
@testable import MakoshTelegram

@MainActor final class TelegramFileArchiveControllerTests: XCTestCase {
    func testPreQueueConfigurationFailureRetainsFrozenFileAndRetryArchivesAfterUnlink() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("Explicit synthetic S3 configuration required") }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: path))
        let dsn = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"])
        let schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-",with: "").lowercased()
        addTeardownBlock {
            guard let db = dsn.withCString({ PQconnectdb($0) }) else { throw MessageArchiveError.database }
            defer { PQfinish(db) }
            PQsetNoticeProcessor(db,{ _,_ in },nil)
            guard let result = PQexec(db,"DROP SCHEMA \"\(schema)\" CASCADE") else { throw MessageArchiveError.database }
            defer { PQclear(result) }
            guard PQresultStatus(result) == PGRES_COMMAND_OK else { throw MessageArchiveError.database }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false,attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = try ArchiveFileRepository(connectionString: dsn,schema: schema,configuration: configuration,
            spoolDirectory: root.appendingPathComponent("queue"),keyProvider: { _,_ in Data(repeating: 0x59,count: 32) })
        var configurationUnavailable = true
        let controller = TelegramFileArchiveController(factory: {
            if configurationUnavailable { throw S3ObjectStoreError.configuration }; return repository
        })
        let source = root.appendingPathComponent("cache"), bytes = Data("synthetic pre-queue retry after unlink".utf8)
        try bytes.write(to: source)
        let identity = MessageArchiveIdentity(service: "telegram",accountID: "synthetic-old-account",conversationID: "1",messageID: "0:1")
        let attachment = MessageArchiveAttachment(id: "retry-file",kind: "file",name: "retry.txt",size: Int64(bytes.count))
        controller.accept(file: source,byteCount: Int64(bytes.count),identity: identity,attachment: attachment)
        XCTAssertNotNil(controller.error); XCTAssertFalse(controller.isBusy)
        try FileManager.default.removeItem(at: source)
        configurationUnavailable = false
        controller.retry()
        for _ in 0..<1000 {
            if !controller.isBusy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.isBusy); XCTAssertNil(controller.error)
        let maybeRecord = try await controller.file(identity: identity,attachmentID: attachment.id)
        let record = try XCTUnwrap(maybeRecord)
        let exported = root.appendingPathComponent("restored")
        try await controller.export(record,to: exported)
        XCTAssertEqual(try Data(contentsOf: exported),bytes)
        let otherIdentity = MessageArchiveIdentity(service: "telegram",accountID: "new-account",conversationID: "1",messageID: "0:1")
        let other = try await controller.file(identity: otherIdentity,attachmentID: attachment.id)
        XCTAssertNil(other)
    }
}
