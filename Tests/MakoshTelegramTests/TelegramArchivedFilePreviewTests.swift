import XCTest
import Foundation
import CPostgres
import MakoshCore
@testable import MakoshTelegram

@MainActor final class TelegramArchivedFilePreviewTests: XCTestCase {
    func testFailureAndCancellationRemovePrivateDirectory() async throws {
        var attempted: URL?
        do {
            _ = try await TelegramArchivedFilePreview.create(name: "../../bad.txt") { file in
                attempted = file
                try Data("synthetic partial".utf8).write(to: file)
                throw MessageArchiveError.invalid
            }
            XCTFail("Expected export failure")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(attempted).deletingLastPathComponent().path))
        let task = Task { @MainActor in
            try await TelegramArchivedFilePreview.create(name: "cancel.txt") { file in
                attempted = file
                try Data("synthetic cancelled".utf8).write(to: file)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected safe error") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(attempted).deletingLastPathComponent().path))
    }

    func testHostileLabelsAndTwoLeaseLifetimes() async throws {
        for (name, expected) in [("../../outside.PDF", "file.PDF"), ("../name.bad-ext", "file"), ("../.hidden", "file"),
                                 ("x.abcdefghijklmnopq", "file"), ("x.t\u{202e}xt", "file")] {
            var first: TelegramArchivedFilePreview? = try await TelegramArchivedFilePreview.create(name: name) { try Data([1, 2, 3]).write(to: $0) }
            let second = try await TelegramArchivedFilePreview.create(name: name) { try Data([4]).write(to: $0) }
            let path = try XCTUnwrap(first).file
            XCTAssertEqual(first?.name, telegramAttachmentName(name)); XCTAssertEqual(path.lastPathComponent, expected)
            XCTAssertNotEqual(path, second.file)
            let fileMode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
            let dirMode = try FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(fileMode?.intValue, 0o600); XCTAssertEqual(dirMode?.intValue, 0o700)
            first = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
            XCTAssertEqual(try Data(contentsOf: second.file), Data([4]))
        }
    }

    func testAuthenticatedPreviewSurvivesUnlinkDeletionAndRepositoryReopen() async throws {
        guard let configPath = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("Explicit synthetic S3 configuration required") }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: configPath))
        let dsn = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"])
        let schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        addTeardownBlock {
            guard let db = dsn.withCString({ PQconnectdb($0) }) else { throw MessageArchiveError.database }
            defer { PQfinish(db) }; PQsetNoticeProcessor(db, { _,_ in }, nil)
            guard let result = PQexec(db, "DROP SCHEMA \"\(schema)\" CASCADE") else { throw MessageArchiveError.database }
            defer { PQclear(result) }
            guard PQresultStatus(result) == PGRES_COMMAND_OK else { throw MessageArchiveError.database }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x59, count: 32)
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "synthetic-preview-account", conversationID: "1", messageID: "0:1")
        let attachment = MessageArchiveAttachment(id: "preview-file", kind: "file", name: "../../private.txt", size: 4)
        let bytes = Data([0, 1, 2, 3]), source = root.appendingPathComponent("cache")
        try bytes.write(to: source)
        let repository = try ArchiveFileRepository(connectionString: dsn, schema: schema, configuration: configuration,
            spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _,_ in key })
        let capture = try ArchiveFileCapture(file: source, byteCount: 4)
        try FileManager.default.removeItem(at: source)
        let record = try await repository.capture(capture, identity: identity, attachment: attachment)
        let messages = try MessageArchiveStore(connectionString: dsn, schema: schema) { _,_ in key }
        _ = try messages.append([MessageArchiveObservation(identity: identity, source: .update, event: .deleted)])
        let reopened = try ArchiveFileRepository(connectionString: dsn, schema: schema, configuration: configuration,
            spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _,_ in key })
        let controller = TelegramFileArchiveController(factory: { reopened })
        var first: TelegramArchivedFilePreview? = try await controller.preview(record)
        let second = try await controller.preview(record)
        let firstURL = try XCTUnwrap(first).file
        XCTAssertEqual(first?.name, "....private.txt")
        XCTAssertEqual(firstURL.lastPathComponent, "file.txt")
        XCTAssertEqual(try Data(contentsOf: firstURL), bytes)
        XCTAssertEqual(try Data(contentsOf: second.file), bytes)
        XCTAssertNotEqual(firstURL, second.file)
        first = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: second.file), bytes)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        fields["plaintextByteCount"] = 999
        let forged = try JSONDecoder().decode(ArchiveFileRecord.self, from: JSONSerialization.data(withJSONObject: fields))
        do { _ = try await controller.preview(forged); XCTFail("Forged metadata must fail authentication") } catch {}
        XCTAssertEqual(try Data(contentsOf: second.file), bytes)
    }
}
