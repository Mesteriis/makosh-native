#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramSavedMessagesForwardModelTests: XCTestCase {
    private final class Lease: TelegramComposerForwardLease { func cancel() {} }
    private final class Provider: TelegramSavedMessagesForwardProvider {
        let accountID: Int64 = -1
        var events: [@MainActor (TelegramMessageActionEvent) -> Void] = []
        var requests: [TelegramSavedMessagesForwardRequest] = []
        func recover(completion: @escaping @MainActor (Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>) -> Void) -> any TelegramComposerForwardLease {
            completion(.success(nil)); return Lease()
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
