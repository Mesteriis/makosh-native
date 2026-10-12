#if DEBUG
import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramForwardModelTests: XCTestCase {
    private final class Lease: TelegramComposerForwardLease { func cancel() {} }
    private final class Provider: TelegramComposerForwardProvider {
        let accountID: Int64 = -1
        var submitted: TelegramComposerDraft?
        var callback: (@MainActor (TelegramComposerForwardEvent) -> Void)?
        func resolve(draft: TelegramComposerDraft, completion: @escaping @MainActor ([TelegramComposerForwardPreview]?) -> Void) -> any TelegramComposerForwardLease {
            completion(draft.forwardIntent?.sources.map { .init(id: String($0.messageID), author: "QA", text: "source", formattedText: try? .init(text: "source"), canCopy: true) })
            return Lease()
        }
        func submit(draft: TelegramComposerDraft, receive: @escaping @MainActor (TelegramComposerForwardEvent) -> Void) -> any TelegramComposerForwardLease {
            submitted = draft; callback = receive; return Lease()
        }
        func consumeAccepted(draft: TelegramComposerDraft, completion: @escaping @MainActor (TelegramComposerDraft?) -> Void) -> any TelegramComposerForwardLease {
            completion(.init(accountID: draft.accountID, chatID: draft.chatID, input: .empty)); return Lease()
        }
    }
    private final class Repository: TelegramComposerDraftRepository {
        let accountID: Int64 = -1
        var reads: [(Int64, @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void)] = []
        var writes: [(TelegramComposerDraft, @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void)] = []
        func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
            reads.append((chatID, completion)); return EmptyDisposable
        }
        func save(_ draft: TelegramComposerDraft, completion: @escaping @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void) { writes.append((draft, completion)) }
    }
    private func fixture() throws -> (TelegramModel, TelegramMessageActionSource, Provider) {
        let model = TelegramModel.syntheticPreview(), provider = Provider()
        model.composerForward.bind(provider); model.selectedChatID = 10001
        let source = try XCTUnwrap(model.messages.last.flatMap(model.actionSource))
        return (model, source, provider)
    }
    private func stage(_ model: TelegramModel, _ source: TelegramMessageActionSource) {
        XCTAssertTrue(model.stageMessageForward(source: source, destinationChatID: 10002, contextID: model.messageActionContextID))
    }
    func testRecipientNavigationPreservesRichCommentReplyAndIndependentSourceDraft() throws {
        let (model, source, _) = try fixture(); model.draft = "source draft"
        model.selectedChatID = 10002
        let value = try TelegramComposerInput(formattedText: .init(text: "comment 😀", entities: [.init(offset: 0, length: 7, kind: .bold)]), selection: .init(location: 2, length: 3))
        XCTAssertTrue(model.updateComposerInput(value, contextID: model.messageActionContextID, chatID: 10002))
        XCTAssertTrue(model.beginReply(to: try XCTUnwrap(model.messages.last), contextID: model.messageActionContextID))
        let reply = model.composerReply.resolved
        let pickedBeforeForward = try XCTUnwrap(model.uploadTarget)
        model.selectedChatID = 10001; stage(model, source)
        XCTAssertEqual(model.selectedChatID, 10002); XCTAssertEqual(model.composerInput, value)
        XCTAssertEqual(model.composerReply.resolved, reply); XCTAssertNotNil(model.composerForwardIntent)
        XCTAssertFalse(model.composerSupportsAttachments); XCTAssertNil(model.uploadTarget)
        model.prepareUpload(source: URL(fileURLWithPath: "/synthetic/stale-picker"), mode: .file,
            target: pickedBeforeForward, captionInput: value, contextID: model.uploadContextID)
        XCTAssertEqual(model.upload.phase, .idle, "A previously captured file picker cannot discard the newly staged forward")
        model.selectedChatID = 10001; XCTAssertEqual(model.draft, "source draft")
        model.selectedChatID = 10002; XCTAssertEqual(model.composerInput, value)
        model.cancelComposerForward(); XCTAssertNil(model.composerForwardIntent)
        XCTAssertEqual(model.composerInput, value); XCTAssertEqual(model.composerReply.resolved, reply)
    }
    func testOptionsContextGuardAndAnotherRecipientKeepOldComment() throws {
        let (model, source, _) = try fixture(); stage(model, source); model.draft = "old recipient comment"
        let intent = try XCTUnwrap(model.composerForwardIntent), context = model.messageActionContextID
        model.updateForwardOptions(hideNames: true, hideCaptions: true, intentID: intent.id, contextID: UUID())
        XCTAssertEqual(model.composerForwardIntent, intent)
        model.updateForwardOptions(hideNames: true, hideCaptions: true, intentID: intent.id, contextID: context)
        XCTAssertTrue(model.composerForwardIntent?.hideCaptions == true)
        XCTAssertTrue(model.moveComposerForward(to: 10003, intentID: intent.id, contextID: context))
        XCTAssertEqual(model.selectedChatID, 10003); XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.composerForwardIntent?.sources, intent.sources)
        XCTAssertTrue(model.composerForwardIntent?.hideCaptions == true)
        model.selectedChatID = 10002; XCTAssertNil(model.composerForwardIntent); XCTAssertEqual(model.draft, "old recipient comment")
    }
    func testStagingWaitsForRecipientDiskDraftAndSaveBeforeSend() throws {
        let (model, source, provider) = try fixture(), repository = Repository()
        model.bindComposerDraftRepository(repository); repository.reads[0].1(.success(nil))
        stage(model, source); XCTAssertTrue(model.isRestoringComposerDraft); XCTAssertNil(model.composerForwardIntent)
        let existing = TelegramComposerDraft(accountID: -1, chatID: 10002, text: "disk comment")
        repository.reads[1].1(.success(existing))
        XCTAssertEqual(model.draft, "disk comment"); XCTAssertNotNil(model.composerForwardIntent)
        XCTAssertFalse(model.sendComposerForward()); XCTAssertNil(provider.submitted)
        repository.writes.last?.1(.success(())); XCTAssertTrue(model.sendComposerForward())
        XCTAssertEqual(provider.submitted?.input, existing.input)
    }
    func testUnavailableRecipientDiskDoesNotOverwriteOrLoseOriginForward() throws {
        let (model, source, _) = try fixture(); stage(model, source); model.draft = "keep"
        let intent = try XCTUnwrap(model.composerForwardIntent), repository = Repository()
        model.bindComposerDraftRepository(repository)
        XCTAssertTrue(model.moveComposerForward(to: 10003, intentID: intent.id, contextID: model.messageActionContextID))
        repository.reads.last?.1(.failure(.incompatibleData))
        XCTAssertNil(model.composerForwardIntent)
        model.selectedChatID = 10002; XCTAssertEqual(model.composerForwardIntent, intent); XCTAssertEqual(model.draft, "keep")
    }
    func testForwardOnlySubmitAndUnknownResultNeverFallBackToOrdinaryOrReply() throws {
        let (model, source, provider) = try fixture(); stage(model, source)
        XCTAssertTrue(model.composerCanSend); XCTAssertTrue(model.sendComposerForward())
        let submitted = try XCTUnwrap(provider.submitted)
        let started = TelegramComposerDraft(accountID: -1, chatID: 10002, input: submitted.input, revision: submitted.revision,
            replyTarget: submitted.replyTarget, forwardIntent: submitted.forwardIntent, forwardDisposition: .submissionStarted)
        provider.callback?(.committing(started)); provider.callback?(.uncertain)
        XCTAssertTrue(model.isForwardComposerLocked); XCTAssertFalse(model.sendComposerForward())
        XCTAssertFalse(model.updateForwardOption(.authorHidden(true), intentID: try XCTUnwrap(submitted.forwardIntent).id,
            contextID: model.messageActionContextID, expectedChatID: 10002,
            expectedRevision: try XCTUnwrap(model.composerForwardRevision)))
        XCTAssertEqual(model.composerForwardIntent, submitted.forwardIntent)
        XCTAssertFalse(model.sendMessage(try .init(text: "must not send alone")))
        XCTAssertFalse(model.updateComposerInput(try .init(formattedText: .init(text: "replacement")), contextID: model.messageActionContextID, chatID: 10002))
        model.cancelComposerForward(); XCTAssertNotNil(model.composerForwardIntent)
    }
    func testRecipientDiskFailureBlocksOrdinaryFallbackAndExplicitRetryRestoresForward() throws {
        let (model, source, provider) = try fixture(), repository = Repository()
        model.bindComposerDraftRepository(repository); repository.reads[0].1(.success(nil))
        stage(model, source); repository.reads.last?.1(.failure(.incompatibleData))
        XCTAssertNotNil(model.composerDraftRecoveryError); XCTAssertNil(model.composerForwardIntent)
        XCTAssertFalse(model.composerCanSend); XCTAssertNil(model.uploadTarget)
        XCTAssertFalse(model.updateComposerInput(try .init(formattedText: .init(text: "must not overwrite")), contextID: model.messageActionContextID, chatID: 10002))
        model.retryComposerDraftRestore(); XCTAssertTrue(model.isRestoringComposerDraft)
        let snapshot = TelegramComposerDraft(accountID: -1, chatID: 10002, text: "saved comment", forwardIntent: .init(sources: [.init(source: source)]))
        repository.reads.last?.1(.success(snapshot))
        XCTAssertNil(model.composerDraftRecoveryError); XCTAssertEqual(model.draft, "saved comment")
        XCTAssertEqual(model.composerForwardIntent, snapshot.forwardIntent); XCTAssertNil(provider.submitted)
    }
    func testAcceptedRecoveryConsumesWithoutSubmitAndAccountStopRejectsStaleStage() throws {
        let (model, source, provider) = try fixture(), repository = Repository()
        model.bindComposerDraftRepository(repository); repository.reads[0].1(.success(nil))
        let intent = TelegramComposerForwardIntent(sources: [.init(source: source)])
        model.selectedChatID = 10002
        let accepted = TelegramComposerDraft(accountID: -1, chatID: 10002, text: "comment", forwardIntent: intent,
            forwardDisposition: .accepted([.init(peerID: 10002, namespace: 1, messageID: 1), .init(peerID: 10002, namespace: 1, messageID: 2)]))
        repository.reads.last?.1(.success(accepted))
        XCTAssertNil(provider.submitted); XCTAssertNil(model.composerForwardIntent); XCTAssertEqual(model.draft, "")
        let old = model.messageActionContextID; model.disconnect()
        XCTAssertFalse(model.stageMessageForward(source: source, destinationChatID: 10002, contextID: old))
    }
}
#endif
