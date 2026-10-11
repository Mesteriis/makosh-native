import XCTest
import ImageIO
import CoreGraphics
import MakoshCore
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadVideoCoverFilesTests: XCTestCase {
    // Exercises the real encrypted S3 and PostgreSQL adapter: replacing a
    // cover must append an independent object and preserve earlier bytes.
    func testSeparateCoverObjectsRestoreExactBytesAndRetainPreviousVersion() async throws {
        let configPath = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])
        let config = try S3ConfigurationFile.read(URL(fileURLWithPath: configPath))
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: config, spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _, _ in Data(repeating: 0x48, count: 32) })
        let source = root.appendingPathComponent("cover.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 320, y: 0, width: 320, height: 320))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let adapter = TelegramPendingUploadFiles(repository: repository), preparation = UUID()
        var descriptors: [TelegramPendingUploadVideoCover] = [], originals: [Data] = []
        for x: CGFloat in [0, 0.5] {
            let cover = try await TelegramUploadVideoCoverIO.stage(source, crop: CGRect(x: x, y: 0, width: 0.5, height: 1))
            defer { try? TelegramUploadFileIO.discard(cover.imageFile) }
            originals.append(try Data(contentsOf: cover.url))
            let descriptor = try await adapter.saveCover(cover, accountID: 1, chatID: 2, preparationID: preparation)
            descriptors.append(descriptor)
            XCTAssertEqual(descriptor.file.attachment.id, "video-cover")
            XCTAssertEqual(descriptor.file.attachment.kind, "photo")
            XCTAssertEqual(descriptor.file.plaintextSHA256, cover.sha256)
            XCTAssertEqual(descriptor.width, 320); XCTAssertEqual(descriptor.height, 320)
            try TelegramUploadFileIO.discard(cover.imageFile)
        }
        XCTAssertNotEqual(originals[0], originals[1])
        XCTAssertNotEqual(descriptors[0].file.id, descriptors[1].file.id)
        XCTAssertNotEqual(descriptors[0].file.objectKey, descriptors[1].file.objectKey)
        let retained = try await repository.files(identity: .init(service: "telegram", accountID: "1", conversationID: "2",
            messageID: "pending-upload:" + preparation.uuidString.lowercased()), attachmentID: "video-cover")
        XCTAssertEqual(Set(retained.map(\.id)), Set(descriptors.map { $0.file.id }))
        for index in descriptors.indices {
            let restored = try await TelegramPendingUploadFiles(repository: repository).restoreCover(descriptors[index],
                accountID: 1, chatID: 2, preparationID: preparation)
            defer { try? TelegramUploadFileIO.discard(restored.imageFile) }
            XCTAssertEqual(try Data(contentsOf: restored.url), originals[index])
            XCTAssertEqual(restored.sha256, descriptors[index].file.plaintextSHA256)
            let preview = try await TelegramUploadVideoCoverIO.preview(restored)
            XCTAssertEqual(preview.image.width, 320); XCTAssertEqual(preview.image.height, 320)
        }
        let first = try XCTUnwrap(descriptors.first)
        for scope in [(Int64(9), Int64(2), preparation), (1, 9, preparation), (1, 2, UUID())] {
            do {
                let unexpected = try await adapter.restoreCover(first, accountID: scope.0, chatID: scope.1, preparationID: scope.2)
                try TelegramUploadFileIO.discard(unexpected.imageFile); XCTFail("Foreign cover scope admitted")
            } catch {}
        }
        let changed = TelegramPendingUploadVideoCover(file: first.file, width: 319, height: 320)
        do {
            let unexpected = try await adapter.restoreCover(changed, accountID: 1, chatID: 2, preparationID: preparation)
            try TelegramUploadFileIO.discard(unexpected.imageFile); XCTFail("Wrong cover geometry admitted")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .invalidImage) }
        do {
            let unexpected = try await adapter.restore(record: first.file, accountID: 1, chatID: 2, preparationID: preparation)
            try TelegramUploadFileIO.discard(unexpected); XCTFail("Cover cannot replace the prepared original")
        } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
    }
}
