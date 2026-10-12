import XCTest
import Foundation
import MakoshCore
import TelegramCore
import SwiftSignalKit
import Postbox
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadVideoCoverReplacementTests: XCTestCase {
    // Catches dropping a cover during replacement/removal, overwriting the
    // original video or caption, duplicate S3 capture after a lost ACK, and
    // admitting a stale editor after another cover or submission has won.
    func testReplaceRemoveRetryAndStaleEditorAgainstRealPostboxAndS3() async throws {
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath:
            XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: root.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x58, count: 32) })
        let source = root.appendingPathComponent("portrait.mov"), image = root.appendingPathComponent("cover.jpg")
        try await writeUploadVideoFixture(source); try writeUploadVideoCoverFixture(image)
        let original = try await TelegramUploadFileIO.stage(source, mode: .video)
        let first = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        let second = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        defer {
            try? TelegramUploadFileIO.discard(original)
            try? TelegramUploadFileIO.discard(first.imageFile); try? TelegramUploadFileIO.discard(second.imageFile)
        }
        let box = try await open(root.appendingPathComponent("postbox"))
        let repository = TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1)
        let session = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: archive) })
        let id = UUID(), target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Cover caption 😀",
            entities: [.init(offset: 0, length: 5, kind: .bold)]))
        try await session.prepare(preparationID: id, file: original, target: target, captionInput: input,
            captionAboveMedia: true, mediaSpoiler: true, originalDraft: nil)
        let initial = try await loaded(session)
        try await session.replaceVideoCover(preparationID: id, file: original, target: target, cover: first)
        let added = try await loaded(session)
        let firstSaved = try XCTUnwrap(added.videoCover)
        XCTAssertEqual(added.schemaVersion, 5); XCTAssertEqual(added.file, initial.file)
        XCTAssertEqual(added.captionInput, input); XCTAssertTrue(added.captionAboveMedia); XCTAssertTrue(added.mediaSpoiler)
        XCTAssertEqual(firstSaved.file.plaintextSHA256, first.sha256)
        // Same operation retry must reuse the durable object after ACK loss.
        try await session.replaceVideoCover(preparationID: id, file: original, target: target, cover: first)
        let retried = try await loaded(session)
        XCTAssertEqual(retried.videoCover, firstSaved)
        do {
            try await session.replaceVideoCover(preparationID: id, file: original, target: target, cover: second)
            XCTFail("Old editor cannot overwrite a newer cover")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        let covered = withCover(original, first)
        try await session.replaceVideoCover(preparationID: id, file: covered, target: target, cover: second)
        let changed = try await loaded(session)
        XCTAssertEqual(changed.videoCover?.file.plaintextSHA256, second.sha256)
        XCTAssertNotEqual(changed.videoCover?.file.id, firstSaved.file.id)
        let restored = try await session.restoreFile(draft: changed)
        defer { try? TelegramUploadFileIO.discard(restored) }
        XCTAssertEqual(restored.videoCover?.sha256, second.sha256)
        XCTAssertEqual(try Data(contentsOf: restored.url), try Data(contentsOf: original.url))
        try await session.replaceVideoCover(preparationID: id, file: withCover(original, second), target: target, cover: nil)
        let removed = try await loaded(session)
        XCTAssertNil(removed.videoCover); XCTAssertEqual(removed.schemaVersion, 4)
        XCTAssertEqual(removed.file, initial.file); XCTAssertEqual(removed.captionInput, input)
        let versions = try await archive.files(identity: initial.file.identity, attachmentID: "video-cover")
        XCTAssertEqual(versions.count, 2, "Retry reuses its committed cover; replacement retains the previous object")
        let oldCover = try await TelegramPendingUploadFiles(repository: archive).restoreCover(firstSaved,
            accountID: 1, chatID: 42, preparationID: id)
        defer { try? TelegramUploadFileIO.discard(oldCover.imageFile) }
        XCTAssertEqual(try Data(contentsOf: oldCover.url), try Data(contentsOf: first.url))
        try await session.save(preparationID: id, chatID: 42, captionInput: input,
            captionAboveMedia: true, mediaSpoiler: true, disposition: .submissionStarted)
        do {
            try await session.replaceVideoCover(preparationID: id, file: original, target: target, cover: first)
            XCTFail("Submission freezes the cover")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
    }

    private func loaded(_ session: TelegramPendingUploadSession) async throws -> TelegramPendingUploadDraft {
        let value = try await session.load(chatID: 42)
        return try XCTUnwrap(value)
    }
    private func withCover(_ file: TelegramUploadFile, _ cover: TelegramUploadVideoCover) -> TelegramUploadFile {
        .init(id: file.id, name: file.name, size: file.size, mode: file.mode,
            pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: file.url, directory: file.directory,
            video: file.video, videoCover: cover)
    }
    private func open(_ root: URL) async throws -> Postbox {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let ready = expectation(description: "Encrypted cover draft Postbox")
        var result: Postbox?
        let operation = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(box) = $0 { result = box; ready.fulfill() } })
        defer { operation.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return try XCTUnwrap(result)
    }
}
