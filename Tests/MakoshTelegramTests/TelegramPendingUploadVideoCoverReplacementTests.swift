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


    // Catches cleanup unlinking an adopted cover before the real store worker opens its FD.
    func testDetachedLegacyCoverWriteRetainsCandidateUntilWorkerCapture() async throws {
        try await heldCoverCapture(batch: false, enabled: false)
    }

    func testDetachedBatchCoverWriteRetainsCandidateUnderBothStoragePolicies() async throws {
        for enabled in [false, true] { try await heldCoverCapture(batch: true, enabled: enabled) }
    }

    func testRegisteredCoverWriteSurvivesRebindBeforePersistenceTaskStarts() async throws {
        try await heldCoverCapture(batch: false, enabled: false, detachBeforeCapture: true)
    }

    func testControllerDeinitRetainsCandidateUntilActualCoverSaveCompletes() async throws {
        try await heldCoverCapture(batch: false, enabled: false, releaseController: true)
    }

    func testDetachedFailedCoverCaptureRetainsCandidateForExplicitRetry() async throws {
        try await heldCoverCapture(batch: false, enabled: false, failCapture: true)
    }

    private func heldCoverCapture(batch: Bool, enabled: Bool, releaseController: Bool = false,
                                  failCapture: Bool = false, detachBeforeCapture: Bool = false) async throws {
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
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
        try await archive.setConversationFileSavingEnabled(identity: .init(service: "telegram", accountID: "1", conversationID: "42", messageID: "synthetic-policy"), enabled: enabled)
        let source = root.appendingPathComponent("portrait.mov"), image = root.appendingPathComponent("cover.jpg")
        try await writeUploadVideoFixture(source); try writeUploadVideoCoverFixture(image)
        let original = try await TelegramUploadFileIO.stage(source, mode: .video)
        let cover = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(original); try? TelegramUploadFileIO.discard(cover.imageFile) }
        let box = try await open(root.appendingPathComponent("postbox"))
        let session = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: box, accountID: 1),
            files: { TelegramPendingUploadFiles(repository: archive) })
        let id = UUID(), item = TelegramUploadBatchItem(id: original.id, file: original)
        if batch {
            try await session.prepare(preparationID: id, items: [item], isGrouped: false, target: target,
                captionInput: .empty, captionAboveMedia: false, mediaSpoiler: false, originalDraft: nil)
        } else {
            try await session.prepare(preparationID: id, file: original, target: target,
                captionInput: .empty, captionAboveMedia: false, mediaSpoiler: false, originalDraft: nil)
        }
        let draft = try await loaded(session), provider = CoverWriteProvider()
        var controller: TelegramUploadController? = TelegramUploadController()
        controller!.bind(provider: provider, recoveryStore: session, requiresRecovery: true)
        let restored = await controller!.restore(draft: draft, bundle: .init(items: batch ? [item] : [.init(id: draft.items[0].id, file: original)], archive: nil),
            target: target, restorationEpoch: controller!.recoveryRestoreEpoch)
        XCTAssertTrue(restored)
        let gate = UploadValidationGate()
        defer { gate.release(); controller?.bind(provider: nil) }
        session.willCaptureVideoCover = {
            try gate.hold()
            if failCapture { throw TelegramUploadFileError.unavailable }
        }
        let edit = try XCTUnwrap(controller!.beginVideoCoverEdit(contextID: id, revision: controller!.videoCoverRevision))
        let committed = await controller!.commitVideoCover(cover, editID: edit)
        XCTAssertTrue(committed)
        if detachBeforeCapture { controller!.bind(provider: CoverWriteProvider(2)) }
        let captureDeadline = ContinuousClock.now + .seconds(3)
        while !gate.started, ContinuousClock.now < captureDeadline { await Task.yield() }
        XCTAssertTrue(gate.started); XCTAssertFalse(gate.ranOnMain)
        weak var weakController = controller
        if releaseController { controller = nil; XCTAssertNil(weakController) }
        else if !detachBeforeCapture { controller!.bind(provider: CoverWriteProvider(2)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.url.path), "In-flight account write owns the candidate until its capture/save completes")
        gate.release()
        if failCapture {
            let failedDeadline = ContinuousClock.now + .seconds(3)
            while controller?.canRetryDetachedRecovery != true, ContinuousClock.now < failedDeadline { await Task.yield() }
            XCTAssertTrue(controller?.canRetryDetachedRecovery == true)
            XCTAssertNotNil(controller?.detachedRecoveryStatus)
            XCTAssertTrue(FileManager.default.fileExists(atPath: cover.url.path), "Unconfirmed detached write must retain its retry bytes")
            session.willCaptureVideoCover = nil
            controller?.retryDetachedRecovery()
        }
        var saved = try await loaded(session)
        let saveDeadline = ContinuousClock.now + .seconds(5)
        while saved.items.first?.videoCover?.file.plaintextSHA256 != cover.sha256, ContinuousClock.now < saveDeadline {
            try await Task.sleep(for: .milliseconds(20)); saved = try await loaded(session)
        }
        XCTAssertEqual(saved.items.first?.videoCover?.file.plaintextSHA256, cover.sha256)
        XCTAssertEqual(saved.disposition, .prepared)
        let savedCover = try XCTUnwrap(saved.items.first?.videoCover)
        if !enabled { XCTAssertEqual(savedCover.file.state, .local) }
        let restoredCover = try await TelegramPendingUploadFiles(repository: archive).restoreCover(savedCover,
            accountID: 1, chatID: 42, preparationID: id, itemID: batch ? item.id : nil)
        defer { try? TelegramUploadFileIO.discard(restoredCover.imageFile) }
        XCTAssertEqual(restoredCover.sha256, cover.sha256)
        let cleanupDeadline = ContinuousClock.now + .seconds(3)
        while FileManager.default.fileExists(atPath: cover.url.path), ContinuousClock.now < cleanupDeadline { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cover.url.path))
        if let controller {
            XCTAssertEqual(controller.phase, .idle); XCTAssertNil(controller.file)
            XCTAssertFalse(controller.canSend); XCTAssertNil(controller.error)
            XCTAssertFalse(controller.canRetryDetachedRecovery); XCTAssertNil(controller.detachedRecoveryStatus)
        }
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


@MainActor private final class CoverWriteProvider: TelegramUploadBatchProvider {
    let accountID: Int64
    init(_ accountID: Int64 = 1) { self.accountID = accountID }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
                captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Cover persistence must not submit"); return CoverWriteLease()
    }
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Cover persistence must not submit"); return CoverWriteLease()
    }
}
@MainActor private final class CoverWriteLease: TelegramUploadLease { func stop() {} }
