#if DEBUG
import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramSelectedMessagesModelTests: XCTestCase {
    private final class Lease: TelegramMessageActionsLease { func cancel() {} }
    private final class Deletion: TelegramSelectedMessagesDeleteProvider {
        let accountID: Int64 = -1
        var callbacks: [@MainActor (TelegramMessageActionEvent) -> Void] = []
        func start(request: TelegramSelectedMessagesDeleteRequest, receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
            callbacks.append(receive); return Lease()
        }
    }
    private final class Copy: TelegramSelectedMessagesCopyProvider {
        let accountID: Int64 = -1
        var callback: (@MainActor (String?) -> Void)?
        func resolve(request: TelegramSelectedMessagesCopyRequest, completion: @escaping @MainActor (String?) -> Void) -> Disposable {
            callback = completion; return EmptyDisposable
        }
    }
    private func fixture() -> TelegramModel {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001; model.draft = "ordinary 😀"
        return model
    }
    private func begin(_ model: TelegramModel, number: Int = 85) throws -> TelegramMessageSelectionSession {
        XCTAssertTrue(model.beginMessageSelection(messageID: "synthetic:10001:\(number)", contextID: model.messageActionContextID, windowID: try XCTUnwrap(model.historyWindowID)))
        return try XCTUnwrap(model.messageSelection.session)
    }
    private func delete(_ model: TelegramModel, _ session: TelegramMessageSelectionSession) -> Bool {
        model.deleteSelectedMessages(forEveryone: false, sessionID: session.id, contextID: session.contextID, expectedRevision: session.revision)
    }
    func testSynchronousDeleteClearsOnlySelectionAndPreservesOrdinaryReply() throws {
        let model = fixture(), message = try XCTUnwrap(model.messages.last)
        XCTAssertTrue(model.beginReply(to: message, contextID: model.messageActionContextID))
        let reply = model.composerReply.resolved, selected = try begin(model)
        XCTAssertTrue(delete(model, selected)); XCTAssertNil(model.messageSelection.session)
        XCTAssertEqual(model.selectedMessagesDelete.phase, .queued)
        XCTAssertEqual(model.draft, "ordinary 😀"); XCTAssertEqual(model.composerReply.resolved, reply)
    }
    func testProtectedBatchCanDeleteAndStaleRevisionCannotDelete() throws {
        let model = fixture(), selected = try begin(model)
        XCTAssertTrue(model.toggleMessageSelection(messageID: "synthetic:10001:120", sessionID: selected.id, contextID: selected.contextID, windowID: try XCTUnwrap(model.historyWindowID)))
        let current = try XCTUnwrap(model.messageSelection.session)
        XCTAssertFalse(current.canForward); XCTAssertFalse(current.canCopy); XCTAssertTrue(current.canDeleteLocally)
        XCTAssertFalse(delete(model, selected)); XCTAssertTrue(delete(model, current))
    }
    func testPendingDeleteBlocksSelectionAndForwardAndUnknownResultCannotRetry() throws {
        let model = fixture(), provider = Deletion(); model.selectedMessagesDelete.bind(provider: provider)
        let selected = try begin(model)
        XCTAssertTrue(delete(model, selected))
        XCTAssertFalse(model.toggleMessageSelection(messageID: "synthetic:10001:86", sessionID: selected.id, contextID: selected.contextID, windowID: try XCTUnwrap(model.historyWindowID)))
        XCTAssertFalse(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: selected.id, contextID: selected.contextID))
        model.cancelMessageSelection(sessionID: selected.id, contextID: selected.contextID); XCTAssertNotNil(model.messageSelection.session)
        model.selectedMessagesDelete.cancel(); provider.callbacks[0](.queued)
        XCTAssertEqual(model.selectedMessagesDelete.phase, .uncertain); XCTAssertNotNil(model.messageSelection.session)
        XCTAssertFalse(delete(model, selected))
        model.selectedChatID = 10002
        XCTAssertFalse(model.stageMessageForwards(sources: selected.sources, destinationChatID: 10001, contextID: selected.contextID))
        XCTAssertNil(model.uploadTarget); XCTAssertFalse(model.sendMessage("must not send"))
    }
    func testLateDeleteAckCannotClearReplacementSelectionAfterChatChange() throws {
        let model = fixture(), provider = Deletion(); model.selectedMessagesDelete.bind(provider: provider)
        let selected = try begin(model); XCTAssertTrue(delete(model, selected))
        model.selectedChatID = 10002
        // Exercise exact callback guard against a newer internally restored selection.
        let source = try XCTUnwrap(model.actionSource(for: try XCTUnwrap(model.messages.first)))
        XCTAssertTrue(model.messageSelection.begin(source: source, contextID: model.messageActionContextID))
        let replacement = model.messageSelection.session
        provider.callbacks[0](.queued)
        XCTAssertEqual(model.messageSelection.session, replacement); XCTAssertEqual(model.draft, "")
    }
    func testCopyRejectsLateSelectionAndPreservesOrdinaryDraft() throws {
        let model = fixture(), provider = Copy(); model.selectedMessagesCopy.bind(provider: provider)
        let selected = try begin(model); var copied: [String] = []
        XCTAssertTrue(model.copySelectedMessages(sessionID: selected.id, contextID: selected.contextID, expectedRevision: selected.revision) { copied.append($0) })
        XCTAssertTrue(model.toggleMessageSelection(messageID: "synthetic:10001:86", sessionID: selected.id, contextID: selected.contextID, windowID: try XCTUnwrap(model.historyWindowID)))
        provider.callback?("stale"); XCTAssertTrue(copied.isEmpty)
        let current = try XCTUnwrap(model.messageSelection.session)
        XCTAssertTrue(model.copySelectedMessages(sessionID: current.id, contextID: current.contextID, expectedRevision: current.revision) { copied.append($0) })
        provider.callback?("safe"); XCTAssertEqual(copied, ["safe"])
        XCTAssertEqual(model.messageSelection.session, current); XCTAssertEqual(model.draft, "ordinary 😀")
    }
    func testDeletingActiveEditSourceClosesExactEditButOtherSourceKeepsIt() throws {
        let model = fixture(), message = try XCTUnwrap(model.messages.first(where: { model.actionSource(for: $0)?.canEdit == true }))
        let source = try XCTUnwrap(model.actionSource(for: message))
        XCTAssertTrue(model.beginMessageEdit(source: source, author: message.author, contextID: model.messageActionContextID))
        let edit = model.messageEditSession
        XCTAssertTrue(delete(model, try begin(model, number: 86)))
        XCTAssertEqual(model.messageEditSession, edit)
        XCTAssertTrue(delete(model, try begin(model, number: Int(source.messageID))))
        XCTAssertNil(model.messageEditSession); XCTAssertEqual(model.draft, "ordinary 😀")
    }
}
#endif
