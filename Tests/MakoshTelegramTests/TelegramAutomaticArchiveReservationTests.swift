import XCTest
import Foundation
import MakoshCore
@testable import MakoshTelegram

@MainActor final class TelegramAutomaticArchiveReservationTests: XCTestCase {
    func testCancelledAdmissionReleasesCapacityAndCannotCaptureLateFile() throws {
        let files = TelegramFileArchiveController()
        func reserve(_ id: Int) -> (any TelegramMediaArchiveReservation)? {
            files.reserveAutomaticCapture(identity: .init(service: "telegram", accountID: "Synthetic", conversationID: "1", messageID: "0:\(id)"),
                attachment: .init(id: "file-\(id)", kind: "file", name: "synthetic.txt", size: 10))
        }
        let a = try XCTUnwrap(reserve(1)), b = try XCTUnwrap(reserve(2)), c = try XCTUnwrap(reserve(3))
        XCTAssertNil(reserve(4)); a.cancel()
        let next = try XCTUnwrap(reserve(4))
        XCTAssertFalse(a.capture(file: URL(fileURLWithPath: "/synthetic/nonexistent"), byteCount: 10))
        b.cancel(); c.cancel(); next.cancel(); XCTAssertNil(files.error)
    }
    func testReservedAutomaticCompletionsSurviveManualPressureConfigurationFailureAndCacheUnlink() async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])
        let config = try S3ConfigurationFile.read(URL(fileURLWithPath: path))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: config, spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _,_ in Data(repeating: 0x59, count: 32) })
        var unavailable = true
        let files = TelegramFileArchiveController(factory: { if unavailable { throw S3ObjectStoreError.configuration }; return repository })
        func identity(_ id: Int) -> MessageArchiveIdentity { .init(service: "telegram", accountID: "Synthetic", conversationID: "1", messageID: "0:\(id)") }
        func attachment(_ id: Int, _ size: Int) -> MessageArchiveAttachment { .init(id: "file-\(id)", kind: "file", name: "synthetic.txt", size: Int64(size)) }
        let data = Data("Synthetic reserved archive handoff".utf8)
        let reserved = try (1...3).map { try XCTUnwrap(files.reserveAutomaticCapture(identity: identity($0), attachment: attachment($0, data.count))) }
        for id in 4...11 {
            let source = root.appendingPathComponent("cache-\(id)"); try data.write(to: source)
            files.accept(file: source, byteCount: Int64(data.count), identity: identity(id), attachment: attachment(id, data.count))
            try FileManager.default.removeItem(at: source)
        }
        for (offset, reservation) in reserved.enumerated() {
            let source = root.appendingPathComponent("auto-\(offset)"); try data.write(to: source)
            XCTAssertTrue(reservation.capture(file: source, byteCount: Int64(data.count)))
            try FileManager.default.removeItem(at: source); reservation.cancel()
        }
        XCTAssertNotNil(files.error)
        XCTAssertNil(files.reserveAutomaticCapture(identity: identity(12), attachment: attachment(12, data.count)))
        unavailable = false; files.retry()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while files.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(files.isBusy); XCTAssertNil(files.error)
        for id in 1...11 {
            let value = try await files.file(identity: identity(id), attachmentID: "file-\(id)")
            let record = try XCTUnwrap(value), output = root.appendingPathComponent("restored-\(id)")
            try await files.export(record, to: output); XCTAssertEqual(try Data(contentsOf: output), data)
        }
        try await repository.setConversationFileSavingEnabled(identity: identity(12), enabled: false)
        let resumed = try XCTUnwrap(files.reserveAutomaticCapture(identity: identity(12), attachment: attachment(12, data.count)))
        let disabledSource = root.appendingPathComponent("disabled"); try data.write(to: disabledSource)
        XCTAssertTrue(resumed.capture(file: disabledSource, byteCount: Int64(data.count)))
        try FileManager.default.removeItem(at: disabledSource); resumed.cancel()
        let disabledDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while files.isBusy, ContinuousClock.now < disabledDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(files.isBusy); XCTAssertNil(files.error)
        let disabledRecord = try await files.file(identity: identity(12), attachmentID: "file-12")
        XCTAssertNil(disabledRecord)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("queue").path).isEmpty)
        let retainedRecord = try await files.file(identity: identity(1), attachmentID: "file-1")
        XCTAssertNotNil(retainedRecord, "S3 OFF preserves previously retained objects")
    }
}
