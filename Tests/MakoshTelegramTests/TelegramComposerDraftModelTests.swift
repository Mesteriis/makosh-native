#if DEBUG
import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramComposerDraftModelTests: XCTestCase {
    private final class Repository: TelegramComposerDraftRepository {
        let accountID: Int64 = -1
        var reads: [(Int64, @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void)] = []
        var writes: [(TelegramComposerDraft, @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void)] = []
        func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
            reads.append((chatID, completion)); return EmptyDisposable
        }
        func save(_ draft: TelegramComposerDraft, completion: @escaping @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void) {
            writes.append((draft, completion))
        }
    }
    private func fixture() -> (TelegramModel, Repository) {
        let model = TelegramModel.syntheticPreview(), repository = Repository()
        model.bindComposerDraftRepository(repository)
        model.selectedChatID = 10001
        return (model, repository)
    }
    func testRestoresExactUnicodeWithoutWritingAndSavesEveryChangeInOrder() throws {
        let (model, repository) = fixture()
        let original = TelegramComposerDraft(accountID: -1, chatID: 10001, text: "  e\u{301} 😀\n")
        repository.reads[0].1(.success(original))
        XCTAssertTrue(model.draft.utf8.elementsEqual(original.text.utf8))
        XCTAssertTrue(repository.writes.isEmpty)
        model.draft = "A"; model.draft = "B"; model.draft = "A"
        XCTAssertEqual(repository.writes.map { $0.0.text }, ["A", "B", "A"])
        XCTAssertNotEqual(repository.writes[0].0.revision, repository.writes[2].0.revision)
        model.selectedChatID = 10002; model.draft = "other"
        model.selectedChatID = 10001
        XCTAssertEqual(model.draft, "A")
        XCTAssertEqual(repository.reads.count, 2)
    }
    func testLateRestoreCannotOverwriteTypingOrExplicitEmptyTombstone() {
        for edited in ["new typing", ""] {
            let (model, repository) = fixture()
            model.draft = edited
            repository.reads[0].1(.success(.init(accountID: -1, chatID: 10001, text: "old disk text")))
            XCTAssertEqual(model.draft, edited)
            XCTAssertEqual(repository.writes.last?.0.text, edited)
        }
    }
    func testOldChatAccountBindingAndDisconnectCallbacksAreIgnored() {
        let (model, repository) = fixture()
        model.selectedChatID = 10002
        repository.reads[0].1(.success(.init(accountID: -1, chatID: 10001, text: "old chat")))
        XCTAssertEqual(model.draft, "")
        let rebound = Repository()
        model.bindComposerDraftRepository(rebound)
        repository.reads[1].1(.success(.init(accountID: -1, chatID: 10002, text: "old binding")))
        XCTAssertEqual(model.draft, "")
        model.disconnect()
        rebound.reads[0].1(.success(.init(accountID: -1, chatID: 10002, text: "disconnected")))
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.phase, .configuration)
    }
    func testForeignSnapshotAndUnknownDataNeverPopulateComposer() {
        let (model, repository) = fixture()
        repository.reads[0].1(.success(.init(accountID: 999, chatID: 10001, text: "foreign")))
        XCTAssertEqual(model.draft, "")
        model.selectedChatID = 10002
        repository.reads[1].1(.failure(.incompatibleData))
        XCTAssertNotNil(model.error)
        XCTAssertTrue(repository.writes.isEmpty)
    }
    func testWriteFailureKeepsVisibleTextAndOldFailureCannotReplaceNewContext() {
        let (model, repository) = fixture()
        model.draft = "unsaved"
        repository.writes[0].1(.failure(.unavailable))
        XCTAssertEqual(model.draft, "unsaved"); XCTAssertNotNil(model.error)
        model.error = nil; model.draft = "newer"
        repository.writes[0].1(.failure(.unavailable))
        XCTAssertNil(model.error)
        model.bindComposerDraftRepository(nil)
        repository.writes[1].1(.failure(.unavailable))
        XCTAssertNil(model.error)
    }
    func testUploadAcknowledgementUsesCapturedRevisionAndPersistsClear() throws {
        let (model, repository) = fixture()
        let target = try XCTUnwrap(model.uploadTarget)
        model.draft = "A"; model.captureUploadDraft(target: target, caption: "A")
        model.draft = "B"; model.draft = "A"
        model.acknowledgeUpload(target: target, caption: "A")
        XCTAssertEqual(model.draft, "A"); XCTAssertEqual(repository.writes.last?.0.text, "A")
        model.captureUploadDraft(target: target, caption: "A")
        model.selectedChatID = 10002; model.draft = "other"
        model.acknowledgeUpload(target: target, caption: "A")
        XCTAssertEqual(model.draft, "other")
        XCTAssertEqual(repository.writes.last?.0.chatID, 10001)
        XCTAssertEqual(repository.writes.last?.0.text, "")
        model.selectedChatID = 10001; XCTAssertEqual(model.draft, "")
    }
    func testFailedClearRemainsDirtyAndRetriesAfterRepositoryRebind() throws {
        let (model, repository) = fixture()
        let target = try XCTUnwrap(model.uploadTarget)
        model.draft = "submitted"
        repository.writes[0].1(.success(()))
        model.captureUploadDraft(target: target, caption: "submitted")
        model.acknowledgeUpload(target: target, caption: "submitted")
        let tombstone = try XCTUnwrap(repository.writes.last?.0)
        repository.writes[1].1(.failure(.unavailable))
        XCTAssertTrue(model.canRetryComposerDraftPersistence); XCTAssertEqual(model.draft, "")
        let rebound = Repository()
        model.bindComposerDraftRepository(rebound)
        XCTAssertEqual(rebound.writes.map { $0.0 }, [tombstone])
        rebound.writes[0].1(.success(()))
        XCTAssertFalse(model.canRetryComposerDraftPersistence); XCTAssertNil(model.error)
        let restarted = TelegramModel.syntheticPreview(), disk = Repository()
        restarted.bindComposerDraftRepository(disk); restarted.selectedChatID = target.chatID
        disk.reads[0].1(.success(tombstone))
        XCTAssertEqual(restarted.draft, "")
    }
    func testExplicitRetrySavesLatestRevisionAndSynchronousReadIsSafe() {
        let (model, repository) = fixture()
        model.draft = "old"; repository.writes[0].1(.failure(.unavailable))
        model.draft = "new"
        model.retryComposerDraftPersistence()
        XCTAssertEqual(repository.writes.map { $0.0.text }, ["old", "new", "new"])
        repository.writes[0].1(.success(()))
        XCTAssertTrue(model.canRetryComposerDraftPersistence)
        repository.writes[2].1(.success(()))
        XCTAssertFalse(model.canRetryComposerDraftPersistence)
        repository.writes[1].1(.failure(.unavailable))
        XCTAssertNil(model.error, "A late failure must not replace a successful retry")
        let synchronous = SynchronousRepository()
        let fresh = TelegramModel.syntheticPreview()
        fresh.bindComposerDraftRepository(synchronous); fresh.selectedChatID = 10001
        XCTAssertEqual(fresh.draft, "synchronous")
    }
    func testReplyAcknowledgementCannotClearABAComposition() throws {
        let (model, repository) = fixture()
        let source = try XCTUnwrap(model.messages.last(where: { $0.isOutgoing }).flatMap(model.actionSource))
        let provider = ReplyProvider(); model.messageActions.bind(provider: provider)
        model.draft = "A"
        XCTAssertTrue(model.performMessageAction(.reply("A"), source: source, contextID: model.messageActionContextID))
        model.draft = "B"; model.draft = "A"
        provider.callback?(.queued)
        XCTAssertEqual(model.draft, "A"); XCTAssertEqual(repository.writes.last?.0.text, "A")
        XCTAssertTrue(model.performMessageAction(.reply("A"), source: source, contextID: model.messageActionContextID))
        provider.callback?(.queued)
        XCTAssertEqual(model.draft, ""); XCTAssertEqual(repository.writes.last?.0.text, "")
    }
    func testSendingCapturedReplyDoesNotReplaceAComposerAlreadyChangedBeforeSubmission() throws {
        let (model, repository) = fixture()
        let source = try XCTUnwrap(model.messages.last(where: { $0.isOutgoing }).flatMap(model.actionSource))
        let provider = ReplyProvider(); model.messageActions.bind(provider: provider)
        model.draft = "captured reply"
        let captured = model.draft
        model.draft = "new composition before submit"
        XCTAssertTrue(model.performMessageAction(.reply(captured), source: source, contextID: model.messageActionContextID))
        provider.callback?(.queued)
        XCTAssertEqual(model.draft, "new composition before submit")
        XCTAssertEqual(repository.writes.map { $0.0.text }, ["captured reply", "new composition before submit"])
    }
    private final class Lease: TelegramMessageActionsLease { func cancel() {} }
    private final class SynchronousRepository: TelegramComposerDraftRepository {
        let accountID: Int64 = -1
        func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
            completion(.success(.init(accountID: accountID, chatID: chatID, text: "synchronous"))); return EmptyDisposable
        }
        func save(_ draft: TelegramComposerDraft, completion: @escaping @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void) { completion(.success(())) }
    }
    private final class ReplyProvider: TelegramMessageActionsProvider {
        let accountID: Int64 = -1
        var callback: (@MainActor (TelegramMessageActionEvent) -> Void)?
        func start(action: TelegramMessageAction, source: TelegramMessageActionSource,
                   receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
            callback = receive; return Lease()
        }
    }
}
#endif
