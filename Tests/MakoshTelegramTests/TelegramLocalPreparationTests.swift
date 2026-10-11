import XCTest
import Foundation
import CoreGraphics
import ImageIO
import MakoshCore
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

@MainActor final class TelegramLocalPreparationTests: XCTestCase {
    // Every resource must survive recovery without making a remote copy, including
    // the raw photo and cover that are separate from the main prepared payload.
    func testExplicitlyDisabledPersonalChatRestoresEveryBatchResourceWithoutS3() async throws {
        let db = try database(), config = try configuration(), root = try directory()
        let chat = peer(Namespaces.Peer.CloudUser), preparation = UUID()
        let target = TelegramUploadTarget(accountID: 1, chatID: chat, title: "Synthetic local preparation")
        let path = root.appendingPathComponent("postbox")
        var expected: [[Data]] = [], saved: TelegramPendingUploadDraft?
        do {
            let archive = try repository(db, config, root)
            try await archive.setConversationFileSavingEnabled(identity: identity(chat), enabled: false)
            let fileURL = root.appendingPathComponent("synthetic.txt")
            let photoURL = root.appendingPathComponent("synthetic.png")
            let videoURL = root.appendingPathComponent("synthetic.mov")
            let coverURL = root.appendingPathComponent("synthetic-cover.jpg")
            try Data("SYNTHETIC_LOCAL_PREPARATION_FILE".utf8).write(to: fileURL)
            try writePhoto(photoURL)
            try await writeUploadVideoFixture(videoURL)
            try writeUploadVideoCoverFixture(coverURL)
            let file = try await TelegramUploadFileIO.stage(fileURL, mode: .file)
            let photo = try await TelegramUploadFileIO.stage(photoURL, mode: .photo)
            let original = try await TelegramUploadFileIO.stageImageSource(photoURL)
            let rawVideo = try await TelegramUploadFileIO.stage(videoURL, mode: .video)
            let cover = try await TelegramUploadVideoCoverIO.stage(coverURL, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
            let video = withCover(rawVideo, cover)
            let items = [TelegramUploadBatchItem(id: UUID(), file: file),
                TelegramUploadBatchItem(id: UUID(), file: photo, originalFile: original),
                TelegramUploadBatchItem(id: UUID(), file: video)]
            defer { for item in items { try? item.discard() } }
            expected = try items.map { item in
                var bytes = [try Data(contentsOf: item.file.url)]
                if let original = item.originalFile { bytes.append(try Data(contentsOf: original.url)) }
                if let cover = item.file.videoCover { bytes.append(try Data(contentsOf: cover.url)) }
                return bytes
            }
            for source in [fileURL, photoURL, videoURL, coverURL] { try FileManager.default.removeItem(at: source) }
            let box = try await open(path); previousBox = box
            let session = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
                files: { TelegramPendingUploadFiles(repository: archive) })
            try await session.prepare(preparationID: preparation, items: items, isGrouped: false, target: target,
                captionInput: .empty, originalDraft: nil)
            saved = try await session.load(chatID: chat)
            let first = try XCTUnwrap(saved)
            XCTAssertEqual(first.schemaVersion, 7)
            XCTAssertEqual(resources(first).count, 5)
            try await assertNoS3(resources(first), config: config)
            try await session.prepare(preparationID: preparation, items: items, isGrouped: false, target: target,
                captionInput: .empty, originalDraft: nil)
            let retry = try await session.load(chatID: chat)
            XCTAssertEqual(retry?.items, first.items, "Committed retry must reuse every local receipt")
            saved = retry
        }
        try await waitForPostboxRelease()
        let archive = try repository(db, config, root)
        let box = try await open(path)
        let session = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
            files: { TelegramPendingUploadFiles(repository: archive) })
        let loaded = try await session.load(chatID: chat), draft = try XCTUnwrap(loaded)
        XCTAssertEqual(draft, saved)
        let restored = try await session.restoreItems(draft: draft)
        defer { for item in restored { try? item.discard() } }
        XCTAssertEqual(restored.count, 3)
        for (item, bytes) in zip(restored, expected) {
            var actual = [try Data(contentsOf: item.file.url)]
            if let original = item.originalFile { actual.append(try Data(contentsOf: original.url)) }
            if let cover = item.file.videoCover { actual.append(try Data(contentsOf: cover.url)) }
            XCTAssertEqual(actual, bytes)
        }
        let resumed = try await archive.resume()
        XCTAssertEqual(resumed, 0, "Local preparation must not become an S3 resume job")
        try await assertNoS3(resources(draft), config: config)
    }

    func testUntouchedGroupDefaultsToLocalPreparation() async throws {
        try await assertLegacyPreparation(namespace: Namespaces.Peer.CloudGroup, enabled: nil)
    }

    func testUntouchedChannelDefaultsToLocalPreparation() async throws {
        try await assertLegacyPreparation(namespace: Namespaces.Peer.CloudChannel, enabled: nil)
    }

    func testExplicitlyEnabledGroupCreatesS3Preparation() async throws {
        try await assertLegacyPreparation(namespace: Namespaces.Peer.CloudGroup, enabled: true)
    }

    func testDisabledPersonalLegacyVideoAndCoverRestoreWithoutS3() async throws {
        try await assertLegacyPreparation(namespace: Namespaces.Peer.CloudUser, enabled: false, video: true)
    }

    private func assertLegacyPreparation(namespace: PeerId.Namespace, enabled: Bool?, video: Bool = false) async throws {
        let db = try database(), config = try configuration(), root = try directory(), chat = peer(namespace)
        let preparation = UUID(), path = root.appendingPathComponent("postbox")
        let target = TelegramUploadTarget(accountID: 1, chatID: chat, title: "Synthetic local legacy preparation")
        var expected: [Data] = [], saved: TelegramPendingUploadDraft?
        do {
            let archive = try repository(db, config, root)
            if let enabled { try await archive.setConversationFileSavingEnabled(identity: identity(chat), enabled: enabled) }
            let source = root.appendingPathComponent(video ? "synthetic.mov" : "synthetic.txt")
            if video { try await writeUploadVideoFixture(source) }
            else { try Data("SYNTHETIC_LOCAL_LEGACY_FILE".utf8).write(to: source) }
            let raw = try await TelegramUploadFileIO.stage(source, mode: video ? .video : .file)
            var file = raw
            if video {
                let image = root.appendingPathComponent("cover.jpg")
                try writeUploadVideoCoverFixture(image)
                let cover = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
                file = withCover(raw, cover)
                try FileManager.default.removeItem(at: image)
            }
            defer { try? TelegramUploadFileIO.discard(file) }
            expected = [try Data(contentsOf: file.url)]
            if let cover = file.videoCover { expected.append(try Data(contentsOf: cover.url)) }
            try FileManager.default.removeItem(at: source)
            let box = try await open(path); previousBox = box
            let session = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
                files: { TelegramPendingUploadFiles(repository: archive) })
            try await session.prepare(preparationID: preparation, file: file, target: target, captionInput: .empty, originalDraft: nil)
            saved = try await session.load(chatID: chat)
            let draft = try XCTUnwrap(saved)
            XCTAssertEqual(draft.schemaVersion, video ? 5 : 3)
            XCTAssertEqual(resources(draft).count, video ? 2 : 1)
            if enabled != true { try await assertNoS3(resources(draft), config: config) }
            else {
                for record in resources(draft) {
                    let remote = try await S3ObjectStore(configuration: config).head(key: record.objectKey)
                    XCTAssertNotNil(remote, "An enabled group must retain the S3-backed preparation path")
                }
            }
        }
        try await waitForPostboxRelease()
        let archive = try repository(db, config, root), box = try await open(path)
        let session = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
            files: { TelegramPendingUploadFiles(repository: archive) })
        let loaded = try await session.load(chatID: chat), draft = try XCTUnwrap(loaded)
        XCTAssertEqual(draft, saved)
        let restored = try await session.restoreFile(draft: draft)
        defer { try? TelegramUploadFileIO.discard(restored) }
        var actual = [try Data(contentsOf: restored.url)]
        if let cover = restored.videoCover { actual.append(try Data(contentsOf: cover.url)) }
        XCTAssertEqual(actual, expected)
        if enabled != true {
            let resumed = try await archive.resume()
            XCTAssertEqual(resumed, 0)
            try await assertNoS3(resources(draft), config: config)
        }
    }

    private func resources(_ draft: TelegramPendingUploadDraft) -> [ArchiveFileRecord] {
        if draft.items.isEmpty { return [draft.file] + (draft.videoCover.map { [$0.file] } ?? []) }
        return draft.items.flatMap { item in
            [item.file] + (item.originalFile.map { [$0] } ?? []) + (item.videoCover.map { [$0.file] } ?? [])
        }
    }
    private func assertNoS3(_ records: [ArchiveFileRecord], config: S3ObjectStoreConfiguration) async throws {
        for record in records {
            let remote = try await S3ObjectStore(configuration: config).head(key: record.objectKey)
            XCTAssertNil(remote, "Disabled chat must leave every new preparation resource absent from S3")
        }
    }
    private func peer(_ namespace: PeerId.Namespace) -> Int64 {
        PeerId(namespace: namespace, id: ._internalFromInt64Value(42)).toInt64()
    }
    private func identity(_ chat: Int64) -> MessageArchiveIdentity {
        .init(service: "telegram", accountID: "1", conversationID: String(chat), messageID: "synthetic-policy")
    }
    private func database() throws -> PendingFilesTestDatabase {
        let db = try PendingFilesTestDatabase(); addTeardownBlock { try db.cleanup() }; return db
    }
    private func configuration() throws -> S3ObjectStoreConfiguration {
        try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
    }
    private func repository(_ db: PendingFilesTestDatabase, _ config: S3ObjectStoreConfiguration, _ root: URL) throws -> ArchiveFileRepository {
        try ArchiveFileRepository(connectionString: db.connectionString, schema: db.schema, configuration: config,
            spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _, _ in Data(repeating: 0x71, count: 32) })
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    private func writePhoto(_ url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func withCover(_ file: TelegramUploadFile, _ cover: TelegramUploadVideoCover) -> TelegramUploadFile {
        .init(id: file.id, name: file.name, size: file.size, mode: file.mode, pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight,
            url: file.url, directory: file.directory, video: file.video, videoCover: cover)
    }
    private weak var previousBox: Postbox?
    private func waitForPostboxRelease() async throws {
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox, "Original encrypted Postbox must release before reopen")
        guard previousBox == nil else { throw TelegramUploadFileError.unavailable }
    }
    private func open(_ root: URL) async throws -> Postbox {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let ready = expectation(description: "Encrypted local preparation Postbox")
        var result: Postbox?
        let operation = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(box) = $0 { result = box; ready.fulfill() } })
        defer { operation.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        let box = try XCTUnwrap(result)
        let stores = expectation(description: "Both owned MediaBox stores ready"); stores.expectedFulfillmentCount = 2
        let storage = (box.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        let cache = (box.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        defer { storage.dispose(); cache.dispose() }
        await fulfillment(of: [stores], timeout: 20)
        return box
    }
}
