#if DEBUG
import XCTest
import Foundation
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadModelTests: XCTestCase {
    private final class Store: TelegramUploadRecoveryStore {
        let accountID: Int64 = -1
        var loads: [(Int64, CheckedContinuation<TelegramPendingUploadDraft?, Error>)] = []
        var restored = 0
        var file: TelegramUploadFile?
        func load(chatID: Int64) async throws -> TelegramPendingUploadDraft? {
            try await withCheckedThrowingContinuation { loads.append((chatID, $0)) }
        }
        func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget, captionInput: TelegramComposerInput, originalDraft: TelegramComposerDraft?) async throws {}
        func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput, disposition: TelegramPendingUploadDisposition) async throws {}
        func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile {
            restored += 1
            guard let file else { throw TelegramUploadFileError.unavailable }; return file
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
        func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease { submissions += 1; return Lease() }
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
