#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramSavedMessagesForwardModelTests: XCTestCase {
    private final class Lease: TelegramComposerForwardLease { func cancel() {} }
    private final class Provider: TelegramSavedMessagesForwardProvider {
        let accountID: Int64 = -1
        var events: [@MainActor (TelegramMessageActionEvent) -> Void] = []
        var requests: [TelegramSavedMessagesForwardRequest] = []
        var recovery: Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError> = .success(nil)
        func recover(completion: @escaping @MainActor (Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>) -> Void) -> any TelegramComposerForwardLease {
            completion(recovery); return Lease()
        }
        func submit(request: TelegramSavedMessagesForwardRequest, receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramComposerForwardLease {
            requests.append(request); events.append(receive); return Lease()
        }
    }
    private func fixture() -> TelegramModel {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001; model.draft = "source ordinary 😀"; return model
    }
    private func select(_ model: TelegramModel, id: Int = 130) throws -> TelegramMessageSelectionSession {
        XCTAssertTrue(model.beginMessageSelection(messageID: "synthetic:10001:\(id)", contextID: model.messageActionContextID, windowID: try XCTUnwrap(model.historyWindowID)))
        return try XCTUnwrap(model.messageSelection.session)
    }
    private func forward(_ model: TelegramModel, _ selected: TelegramMessageSelectionSession) -> Bool {
        model.forwardSelectedMessagesToSaved(sessionID: selected.id, contextID: selected.contextID, expectedRevision: selected.revision)
    }
    func testSynchronousSavedForwardKeepsChatAndOrdinaryReplyWithoutRecipientComposer() throws {
        let model = fixture(); XCTAssertEqual(model.messageActionForwardDestinations.first?.id, -1)
        XCTAssertTrue(model.beginReply(to: try XCTUnwrap(model.messages.last), contextID: model.messageActionContextID))
        let reply = model.composerReply.resolved, selected = try select(model)
        XCTAssertTrue(forward(model, selected)); XCTAssertEqual(model.savedMessagesForward.phase, .queued)
        XCTAssertNil(model.messageSelection.session); XCTAssertNil(model.composerForwardIntent)
        XCTAssertEqual(model.selectedChatID, 10001); XCTAssertEqual(model.draft, "source ordinary 😀")
        XCTAssertEqual(model.composerReply.resolved, reply)
    }
    func testRetargetStagedForwardToSavedKeepsOriginCommentReplyAndChat() throws {
        let model = fixture(), source = try XCTUnwrap(model.messages.last.flatMap(model.actionSource))
        XCTAssertTrue(model.stageMessageForwards(sources: [source], destinationChatID: 10002, contextID: model.messageActionContextID))
        model.draft = "old recipient comment 😀"
        XCTAssertTrue(model.beginReply(to: try XCTUnwrap(model.messages.last), contextID: model.messageActionContextID))
        let reply = model.composerReply.resolved, intent = try XCTUnwrap(model.composerForwardIntent)
        model.updateForwardOptions(hideNames: true, hideCaptions: true, intentID: intent.id, contextID: model.messageActionContextID)
        let moved = model.moveComposerForward(to: -1, intentID: intent.id, contextID: model.messageActionContextID)
        XCTAssertTrue(moved, "Explicit Saved re-target must enqueue without opening another composer")
        guard moved else { return }
        XCTAssertEqual(model.selectedChatID, 10002); XCTAssertEqual(model.draft, "old recipient comment 😀")
        XCTAssertEqual(model.composerReply.resolved, reply); XCTAssertNil(model.composerForwardIntent)
        XCTAssertEqual(model.savedMessagesForward.phase, .queued)
        XCTAssertEqual(model.savedMessagesForward.request?.draft.text, "")
        XCTAssertFalse(model.savedMessagesForward.request?.draft.forwardIntent?.hideNames ?? true)
        XCTAssertFalse(model.savedMessagesForward.request?.draft.forwardIntent?.hideCaptions ?? true)
    }
    func testRetargetRejectsStalePickerAndUnknownResultLocksOnlyItsOrigin() throws {
        let model = fixture(), provider = Provider(), source = try XCTUnwrap(model.messages.last.flatMap(model.actionSource))
        model.savedMessagesForward.bind(provider)
        XCTAssertTrue(model.stageMessageForwards(sources: [source], destinationChatID: 10002, contextID: model.messageActionContextID))
        let intent = try XCTUnwrap(model.composerForwardIntent), oldRevision = try XCTUnwrap(model.composerForwardRevision)
        model.draft = "newer origin comment"
        XCTAssertFalse(model.moveComposerForward(to: -1, intentID: intent.id, contextID: model.messageActionContextID, expectedRevision: oldRevision, expectedOriginChatID: 10002))
        XCTAssertFalse(model.moveComposerForward(to: -1, intentID: intent.id, contextID: model.messageActionContextID, expectedRevision: model.composerForwardRevision, expectedOriginChatID: 10001))
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(model.moveComposerForward(to: -1, intentID: intent.id, contextID: model.messageActionContextID, expectedRevision: model.composerForwardRevision, expectedOriginChatID: 10002))
        XCTAssertTrue(model.isForwardComposerLocked); XCTAssertFalse(model.composerCanSend)
        model.savedMessagesForward.cancel(); model.cancelComposerForward(); model.draft = "must not overwrite locked origin"
        XCTAssertEqual(model.draft, "newer origin comment"); XCTAssertEqual(model.composerForwardIntent?.id, intent.id)
        XCTAssertTrue(model.isForwardComposerLocked); XCTAssertFalse(model.composerCanSend)
        model.selectedChatID = 10003; model.draft = "another chat"
        XCTAssertFalse(model.isForwardComposerLocked); XCTAssertTrue(model.composerCanSend)
        provider.events[0](.queued)
        XCTAssertEqual(model.draft, "another chat"); XCTAssertEqual(model.savedMessagesForward.phase, .uncertain)
    }
    func testRetargetLateAcceptanceClearsCapturedOriginWithoutChangingAnotherChat() throws {
        let model = fixture(), provider = Provider(), source = try XCTUnwrap(model.messages.last.flatMap(model.actionSource))
        model.savedMessagesForward.bind(provider)
        XCTAssertTrue(model.stageMessageForwards(sources: [source], destinationChatID: 10002, contextID: model.messageActionContextID))
        model.draft = "origin comment"
        XCTAssertTrue(model.beginReply(to: try XCTUnwrap(model.messages.last), contextID: model.messageActionContextID))
        let reply = model.composerReply.resolved, intent = try XCTUnwrap(model.composerForwardIntent)
        XCTAssertTrue(model.moveComposerForward(to: -1, intentID: intent.id, contextID: model.messageActionContextID))
        model.selectedChatID = 10003; model.draft = "new chat input"
        provider.events[0](.queued)
        XCTAssertEqual(model.selectedChatID, 10003); XCTAssertEqual(model.draft, "new chat input")
        model.selectedChatID = 10002
        XCTAssertNil(model.composerForwardIntent); XCTAssertEqual(model.draft, "origin comment")
        XCTAssertEqual(model.composerReply.resolved, reply)
    }
    func testUnreadableSavedRecoveryBlocksPreparedForwardButKeepsOtherOrdinaryInputAvailable() throws {
        let model = fixture(), provider = Provider(), source = try XCTUnwrap(model.messages.last.flatMap(model.actionSource))
        XCTAssertTrue(model.stageMessageForwards(sources: [source], destinationChatID: 10002, contextID: model.messageActionContextID))
        model.draft = "uncertain origin comment"
        let intent = try XCTUnwrap(model.composerForwardIntent)
        provider.recovery = .failure(.incompatibleData)
        model.savedMessagesForward.bind(provider)
        XCTAssertEqual(model.savedMessagesForward.phase, .uncertain)
        XCTAssertNil(model.savedMessagesForward.request)
        XCTAssertTrue(model.isForwardComposerLocked)
        XCTAssertFalse(model.composerCanSend)
        model.cancelComposerForward(); model.draft = "must not overwrite unknown origin"
        XCTAssertEqual(model.draft, "uncertain origin comment")
        XCTAssertEqual(model.composerForwardIntent?.id, intent.id)
        model.selectedChatID = 10003; model.draft = "another ordinary input"
        XCTAssertFalse(model.isForwardComposerLocked); XCTAssertTrue(model.composerCanSend)
        XCTAssertTrue(provider.requests.isEmpty)
    }
    func testProtectedAndStaleSelectionRefuseWholeBatch() throws {
        let model = fixture(), provider = Provider(); model.savedMessagesForward.bind(provider)
        let selected = try select(model, id: 120); XCTAssertFalse(forward(model, selected)); XCTAssertTrue(provider.events.isEmpty)
        model.cancelMessageSelection(sessionID: selected.id, contextID: selected.contextID)
        let valid = try select(model)
        XCTAssertTrue(model.toggleMessageSelection(messageID: "synthetic:10001:122", sessionID: valid.id, contextID: valid.contextID, windowID: try XCTUnwrap(model.historyWindowID)))
        XCTAssertFalse(forward(model, valid)); XCTAssertTrue(provider.events.isEmpty)
    }
    func testLateQueueAckCannotClearNewSelectionOrNewChatInput() throws {
        let model = fixture(), provider = Provider(); model.savedMessagesForward.bind(provider)
        let selected = try select(model); XCTAssertTrue(forward(model, selected))
        model.selectedChatID = 10002; model.draft = "new ordinary"
        let source = try XCTUnwrap(model.messages.first.flatMap(model.actionSource))
        XCTAssertTrue(model.messageSelection.begin(source: source, contextID: model.messageActionContextID))
        let replacement = model.messageSelection.session
        provider.events[0](.queued)
        XCTAssertEqual(model.messageSelection.session, replacement); XCTAssertEqual(model.selectedChatID, 10002)
        XCTAssertEqual(model.draft, "new ordinary"); XCTAssertNil(model.composerForwardIntent)
    }
    func testCancelledWaitingCannotResubmitButNormalRecipientStillStages() throws {
        let model = fixture(), provider = Provider(); model.savedMessagesForward.bind(provider)
        let selected = try select(model); XCTAssertTrue(forward(model, selected)); model.savedMessagesForward.cancel()
        XCTAssertFalse(forward(model, selected)); XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: selected.id, contextID: selected.contextID, expectedRevision: selected.revision))
        XCTAssertEqual(model.selectedChatID, 10002); XCTAssertNotNil(model.composerForwardIntent)
    }
}
#endif
