#if DEBUG
import XCTest
import Foundation
import CoreGraphics
import ImageIO
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadModelTests: XCTestCase {
    private final class Store: TelegramUploadRecoveryStore {
        let accountID: Int64 = -1
        var loads: [(Int64, CheckedContinuation<TelegramPendingUploadDraft?, Error>)] = []
        var restored = 0
        var file: TelegramUploadFile?
        var holdPrepare = false, holdRestore = false
        var prepareGate: CheckedContinuation<Void, Error>?
        var restoreGate: CheckedContinuation<Void, Error>?
        var savedDraft: TelegramPendingUploadDraft?
        func replaceVideoCover(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                               cover: TelegramUploadVideoCover?) async throws { throw TelegramUploadFileError.unavailable }
        func load(chatID: Int64) async throws -> TelegramPendingUploadDraft? {
            try await withCheckedThrowingContinuation { loads.append((chatID, $0)) }
        }
        func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget, captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false, originalDraft: TelegramComposerDraft?) async throws {
            if holdPrepare { try await withCheckedThrowingContinuation { prepareGate = $0 } }
        }
        func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false, disposition: TelegramPendingUploadDisposition) async throws {
            guard let current = savedDraft else { return }
            guard current.id == preparationID, current.chatID == chatID else { throw TelegramUploadFileError.unavailable }
            savedDraft = TelegramPendingUploadDraft(id: current.id, accountID: accountID, chatID: chatID,
                title: current.title, captionInput: captionInput, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler,
                originalDraft: current.originalDraft, replyTarget: current.replyTarget, file: current.file, disposition: disposition)
        }
        func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile {
            restored += 1
            guard let file else { throw TelegramUploadFileError.unavailable }
            if holdRestore { try await withCheckedThrowingContinuation { restoreGate = $0 } }
            return file
        }
    }
    private final class Composer: TelegramComposerDraftRepository {
        let accountID: Int64 = -1
        let value: TelegramComposerDraft?
        var writes: [TelegramComposerDraft] = []
        init(_ value: TelegramComposerDraft?) { self.value = value }
        func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
            completion(.success(value?.chatID == chatID ? value : nil)); return EmptyDisposable
        }
        func save(_ draft: TelegramComposerDraft, completion: @escaping @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void) { writes.append(draft); completion(.success(())) }
    }
    private func eventually(_ condition: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < end { await Task.yield() }
        XCTAssertTrue(condition())
    }
    private func pending(original: TelegramComposerDraft? = nil, disposition: TelegramPendingUploadDisposition = .prepared, reply: TelegramComposerReplyTarget? = nil) throws -> TelegramPendingUploadDraft {
        let fixture = try pendingUploadFixture(accountID: -1, chatID: 10001)
        return TelegramPendingUploadDraft(id: fixture.id, accountID: -1, chatID: 10001, title: "Synthetic", captionInput: fixture.captionInput,
            originalDraft: original, replyTarget: reply, file: fixture.file, disposition: disposition)
    }
    func testStaleLoadAcrossChatAndDisconnectCannotRestore() async throws {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        let store = Store()
        model.bindPendingUploadRecovery(store, replyProvider: nil)
        await eventually { store.loads.count == 1 }
        XCTAssertTrue(model.isRestoringPendingUpload)
        model.draft = "original caption awaiting recovery"
        XCTAssertFalse(model.composerCanSend)
        XCTAssertFalse(model.sendMessage(model.composerInput.formattedText))
        let replySource = try XCTUnwrap(model.messages.compactMap { model.actionSource(for: $0) }.first { $0.canReply })
        XCTAssertFalse(model.performMessageAction(.reply("backup"), source: replySource, contextID: model.messageActionContextID))
        XCTAssertNil(model.uploadTarget(replyTo: nil, contextID: model.uploadContextID))
        model.selectedChatID = 10002
        await eventually { store.loads.count == 2 }
        store.loads[0].1.resume(returning: try pending())
        store.loads[1].1.resume(returning: nil)
        await eventually { !model.isRestoringPendingUpload }
        XCTAssertEqual(store.restored, 0); XCTAssertEqual(model.upload.phase, .idle)
        model.selectedChatID = 10001
        await eventually { store.loads.count == 3 }
        model.disconnect()
        store.loads[2].1.resume(returning: try pending())
        await Task.yield()
        XCTAssertEqual(store.restored, 0); XCTAssertEqual(model.upload.phase, .idle)
    }
    func testAcceptedMarkerClearsOnlyOriginalExactRevisionAndCancelledDoesNothing() async throws {
        for newer in [false, true] {
            let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
            let original = TelegramComposerDraft(accountID: -1, chatID: 10001, input: try TelegramComposerInput(formattedText: TelegramFormattedText(text: "rich", entities: [.init(offset: 0, length: 4, kind: .bold)])))
            let repository = Composer(original); model.bindComposerDraftRepository(repository)
            if newer { model.draft = "new revision" }
            let store = Store(); model.bindPendingUploadRecovery(store, replyProvider: nil)
            await eventually { store.loads.count == 1 }
            store.loads[0].1.resume(returning: try pending(original: original, disposition: .accepted(localMessageID: "synthetic:1")))
            await eventually { !model.isRestoringPendingUpload }
            XCTAssertEqual(model.draft, newer ? "new revision" : "")
            XCTAssertEqual(store.restored, 0)
        }
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001; model.draft = "keep"
        let store = Store(); model.bindPendingUploadRecovery(store, replyProvider: nil)
        await eventually { store.loads.count == 1 }
        store.loads[0].1.resume(returning: try pending(disposition: .cancelled))
        await eventually { !model.isRestoringPendingUpload }
        XCTAssertEqual(model.draft, "keep"); XCTAssertEqual(store.restored, 0)
    }
    func testMissingReplyRefusesPreparedRecoveryAndExplicitRetryLoadsAgain() async throws {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        let store = Store(); model.bindPendingUploadRecovery(store, replyProvider: nil)
        await eventually { store.loads.count == 1 }
        store.loads[0].1.resume(returning: try pending(reply: .init(peerID: 10001, namespace: 0, messageID: 5)))
        await eventually { !model.isRestoringPendingUpload }
        XCTAssertNotNil(model.pendingUploadRecoveryError); XCTAssertEqual(store.restored, 0)
        model.draft = "ordinary backup"
        XCTAssertFalse(model.composerCanSend)
        XCTAssertFalse(model.sendMessage(model.composerInput.formattedText))
        XCTAssertNil(model.uploadTarget(replyTo: nil, contextID: model.uploadContextID))
        model.retryPendingUploadRecovery()
        await eventually { store.loads.count == 2 }
        store.loads[1].1.resume(returning: nil)
        await eventually { !model.isRestoringPendingUpload }
        XCTAssertNil(model.pendingUploadRecoveryError)
    }
    private final class Lease: TelegramUploadLease { func stop() {} }
    private final class Provider: TelegramUploadProvider {
        let accountID: Int64 = -1
        var submissions = 0
        func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease { submissions += 1; return Lease() }
    }
    func testSnapshotLoadedBeforeDetachedSaveCannotRestoreAfterItsFileExportCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic.jpg")
        let image = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
            bytesPerRow: 40, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)?.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let restoredFile = try await TelegramUploadFileIO.stage(source, mode: .photo)
        addTeardownBlock { try TelegramUploadFileIO.discard(restoredFile) }
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        let store = Store(), provider = Provider()
        store.holdPrepare = true; store.holdRestore = true; store.file = restoredFile
        model.upload.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        model.upload.prepare(source: source, mode: .photo,
            target: .init(accountID: -1, chatID: 10001, title: "Synthetic"), caption: "initial")
        await eventually { store.prepareGate != nil }
        let id = try XCTUnwrap(model.upload.preparationContextID)
        let oldDraft = try pendingUploadMutating(pendingUploadFixture(accountID: -1, chatID: 10001, id: id)) {
            var record = $0["file"] as! [String: Any], attachment = record["attachment"] as! [String: Any]
            attachment["kind"] = "photo"; attachment["name"] = restoredFile.name; attachment["size"] = restoredFile.size
            record["attachment"] = attachment; record["plaintextByteCount"] = restoredFile.size; $0["file"] = record
        }
        XCTAssertTrue(oldDraft.isValid); store.savedDraft = oldDraft
        let latest = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "latest 😀",
            entities: [.init(offset: 0, length: 6, kind: .bold)]), selection: .init(location: 7, length: 2))
        XCTAssertTrue(model.upload.updateCaptionInput(latest, contextID: model.upload.captionContextID))
        XCTAssertTrue(model.upload.updateCaptionPlacement(true, contextID: model.upload.captionContextID, revision: model.upload.captionRevision))
        XCTAssertTrue(model.upload.updateMediaSpoiler(true, contextID: model.upload.captionContextID, revision: model.upload.captionRevision))
        model.upload.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
        model.bindPendingUploadRecovery(store, replyProvider: nil)
        await eventually { store.loads.count == 1 }
        store.loads[0].1.resume(returning: oldDraft)
        await eventually { store.restoreGate != nil }
        store.prepareGate?.resume(); store.prepareGate = nil
        await eventually { store.savedDraft?.mediaSpoiler == true && model.upload.detachedRecoveryStatus == nil }
        let fresh = try XCTUnwrap(store.savedDraft)
        XCTAssertEqual(fresh.captionInput, latest); XCTAssertTrue(fresh.captionAboveMedia)
        store.restoreGate?.resume(); store.restoreGate = nil
        await eventually { !model.isRestoringPendingUpload }
        XCTAssertEqual(model.upload.phase, .idle, "The completed detached save must invalidate an already loaded snapshot")
        XCTAssertNotNil(model.pendingUploadRecoveryError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredFile.url.path))
        XCTAssertEqual(provider.submissions, 0)
        guard model.upload.phase == .idle else { model.disconnect(); return }
        let freshFile = try await TelegramUploadFileIO.stage(source, mode: .photo)
        addTeardownBlock { try TelegramUploadFileIO.discard(freshFile) }
        store.file = freshFile; store.holdRestore = false
        model.retryPendingUploadRecovery()
        await eventually { store.loads.count == 2 }
        store.loads[1].1.resume(returning: fresh)
        await eventually { !model.isRestoringPendingUpload }
        XCTAssertEqual(model.upload.phase, .ready); XCTAssertTrue(model.upload.mediaSpoiler)
        XCTAssertTrue(model.upload.captionAboveMedia); XCTAssertEqual(model.upload.captionInput, latest)
        XCTAssertEqual(provider.submissions, 0)
        model.disconnect()
    }
    func testPreparedAndUnknownSubmissionRestoreWithoutAutomaticSendOrNewerDraftOverwrite() async throws {
        for unknown in [false, true] {
            let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
            let original = TelegramComposerDraft(accountID: -1, chatID: 10001, text: "original")
            model.bindComposerDraftRepository(Composer(original))
            if unknown { model.draft = "newer" }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            addTeardownBlock { try FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("synthetic.txt")
            try Data("Synthetic 😀".utf8).write(to: source)
            let file = try await TelegramUploadFileIO.stage(source, mode: .file)
            addTeardownBlock { try TelegramUploadFileIO.discard(file) }
            let store = Store(); store.file = file
            let provider = Provider()
            model.upload.bind(provider: provider, recoveryStore: store, requiresRecovery: true)
            model.bindPendingUploadRecovery(store, replyProvider: nil)
            await eventually { store.loads.count == 1 }
            store.loads[0].1.resume(returning: try pending(original: original, disposition: unknown ? .submissionStarted : .prepared))
            await eventually { !model.isRestoringPendingUpload }
            XCTAssertEqual(model.upload.phase, unknown ? .uncertain : .ready)
            XCTAssertEqual(provider.submissions, 0)
            XCTAssertEqual(model.isComposerSuspended, !unknown)
            if unknown { XCTAssertEqual(model.draft, "newer") }
            else {
                XCTAssertEqual(model.composerInput, .empty)
                model.upload.cancelPreparation()
                XCTAssertEqual(model.draft, "original")
            }
            model.disconnect()
        }
    }
}
#endif
