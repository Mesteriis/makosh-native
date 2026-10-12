import XCTest
import MakoshCore
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadVideoFilesTests: XCTestCase {
    func testEncryptedS3VideoRestoreRequiresExactFrozenDescriptor() async throws {
        let configPath = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])
        let config = try S3ConfigurationFile.read(URL(fileURLWithPath: configPath))
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: config, spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _, _ in Data(repeating: 0x47, count: 32) })
        let source = root.appendingPathComponent("portrait.mp4")
        try await writeUploadVideoFixture(source, rotated: true, timescale: 30)
        let file = try await TelegramUploadFileIO.stage(source, mode: .video)
        addTeardownBlock { try TelegramUploadFileIO.discard(file) }
        let frozen = try XCTUnwrap(file.video)
        let original = try Data(contentsOf: file.url), preparation = UUID()
        let adapter = TelegramPendingUploadFiles(repository: repository)
        let record = try await adapter.save(file: file, accountID: 1, chatID: 2, preparationID: preparation)
        XCTAssertEqual(record.attachment.kind, "video")
        XCTAssertEqual(record.attachment.name, "portrait.mp4")
        try TelegramUploadFileIO.discard(file)
        let restored = try await TelegramPendingUploadFiles(repository: repository).restore(record: record,
            accountID: 1, chatID: 2, preparationID: preparation, video: frozen)
        addTeardownBlock { try TelegramUploadFileIO.discard(restored) }
        XCTAssertEqual(restored.mode, .video); XCTAssertEqual(restored.video, frozen)
        XCTAssertEqual(restored.pixelWidth, 16); XCTAssertEqual(restored.pixelHeight, 32)
        XCTAssertEqual(try Data(contentsOf: restored.url), original)
        // Authenticated bytes alone are insufficient when pending metadata differs.
        for changed in [
            TelegramUploadVideoMetadata(width: 32, height: 16, duration: frozen.duration, hasAudio: false, inCollage: true),
            TelegramUploadVideoMetadata(width: 16, height: 32, duration: 1, hasAudio: false, inCollage: true),
            TelegramUploadVideoMetadata(width: 16, height: 32, duration: frozen.duration, hasAudio: true, inCollage: true)
        ] {
            do {
                let unexpected = try await adapter.restore(record: record, accountID: 1, chatID: 2,
                    preparationID: preparation, video: changed)
                try TelegramUploadFileIO.discard(unexpected)
                XCTFail("Restoration cannot replace the frozen descriptor with a fresh probe")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidVideo) }
        }
        do {
            let unexpected = try await adapter.restore(record: record, accountID: 1, chatID: 2, preparationID: preparation)
            try TelegramUploadFileIO.discard(unexpected); XCTFail("Video requires its persisted descriptor")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        // Never regenerate inCollage from final single-message grouping.
        let ungrouped = TelegramUploadVideoMetadata(width: 16, height: 32, duration: frozen.duration,
            hasAudio: false, inCollage: false)
        let changedPreparation = try await adapter.restore(record: record, accountID: 1, chatID: 2,
            preparationID: preparation, video: ungrouped)
        addTeardownBlock { try TelegramUploadFileIO.discard(changedPreparation) }
        XCTAssertEqual(changedPreparation.video?.inCollage, false)
        XCTAssertEqual(try Data(contentsOf: changedPreparation.url), original)
    }
}
