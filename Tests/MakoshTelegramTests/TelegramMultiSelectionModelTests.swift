#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramMultiSelectionModelTests: XCTestCase {
    private func fixture() -> TelegramModel {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        return model
    }
    private func id(_ value: Int) -> String { "synthetic:10001:\(value)" }
    private func begin(_ model: TelegramModel, number: Int = 85) throws -> TelegramMessageSelectionSession {
        XCTAssertTrue(model.beginMessageSelection(messageID: id(number), contextID: model.messageActionContextID,
            windowID: try XCTUnwrap(model.historyWindowID)))
        return try XCTUnwrap(model.messageSelection.session)
    }
    func testOrderedBatchStagesRecipientWithoutSendingAndPreservesOrdinaryDraft() throws {
        let model = fixture(); model.draft = "ordinary e\u{301} 😀"
        let context = model.messageActionContextID, window = try XCTUnwrap(model.historyWindowID)
        let session = try begin(model)
        XCTAssertTrue(model.toggleMessageSelection(messageID: id(81), sessionID: session.id, contextID: context, windowID: window))
        XCTAssertTrue(model.toggleMessageSelection(messageID: id(83), sessionID: session.id, contextID: context, windowID: window))
        let selected = try XCTUnwrap(model.messageSelection.session)
        XCTAssertEqual(selected.sources.map(\.messageID), [81, 83, 85]); XCTAssertTrue(selected.canForward)
        XCTAssertTrue(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: session.id, contextID: context, expectedRevision: selected.revision))
        XCTAssertNil(model.messageSelection.session); XCTAssertEqual(model.selectedChatID, 10002)
        XCTAssertEqual(model.composerForwardIntent?.sources.map(\.messageID), [81, 83, 85])
        XCTAssertEqual(model.composerForwardDisposition, .prepared)
        model.selectedChatID = 10001; XCTAssertEqual(model.draft, "ordinary e\u{301} 😀")
    }
    func testPaginationRetainsFrozenSelectionButRejectsOldWindowToggle() throws {
        let model = fixture(), context = model.messageActionContextID
        let window = try XCTUnwrap(model.historyWindowID), session = try begin(model)
        model.loadOlderMessages()
        XCTAssertNotEqual(model.historyWindowID, window)
        XCTAssertEqual(model.messageSelection.session?.sources, session.sources)
        XCTAssertFalse(model.toggleMessageSelection(messageID: id(40), sessionID: session.id, contextID: context, windowID: window))
        XCTAssertTrue(model.toggleMessageSelection(messageID: id(40), sessionID: session.id, contextID: context, windowID: try XCTUnwrap(model.historyWindowID)))
        XCTAssertEqual(model.messageSelection.session?.sources.map(\.messageID), [40, 85])
        model.showLatestMessages()
        XCTAssertEqual(model.messageSelection.session?.sources.map(\.messageID), [40, 85])
    }
    func testStaleSessionContextRevisionChatAndAccountCannotStageOrToggle() throws {
        let model = fixture(), context = model.messageActionContextID, window = try XCTUnwrap(model.historyWindowID)
        let first = try begin(model)
        XCTAssertFalse(model.toggleMessageSelection(messageID: id(81), sessionID: UUID(), contextID: context, windowID: window))
        XCTAssertFalse(model.toggleMessageSelection(messageID: id(81), sessionID: first.id, contextID: UUID(), windowID: window))
        XCTAssertTrue(model.toggleMessageSelection(messageID: id(81), sessionID: first.id, contextID: context, windowID: window))
        XCTAssertFalse(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: first.id, contextID: context, expectedRevision: first.revision))
        model.cancelMessageSelection(sessionID: UUID(), contextID: context)
        XCTAssertNotNil(model.messageSelection.session)
        model.cancelMessageSelection(sessionID: first.id, contextID: context)
        XCTAssertNil(model.messageSelection.session)
        let replacement = try begin(model)
        XCTAssertNotEqual(first.id, replacement.id)
        XCTAssertFalse(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: first.id, contextID: context))
        model.selectedChatID = 10002; XCTAssertNil(model.messageSelection.session)
        XCTAssertFalse(model.toggleMessageSelection(messageID: id(81), sessionID: replacement.id, contextID: context, windowID: window))
        model.selectedChatID = 10001
        let last = try begin(model); model.disconnect()
        XCTAssertNil(model.messageSelection.session)
        XCTAssertFalse(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: last.id, contextID: context))
    }
    func testSameChatStagingClearsSelectionAndCancelPreservesReply() throws {
        let model = fixture(); model.draft = "ordinary reply"
        let message = try XCTUnwrap(model.messages.last)
        XCTAssertTrue(model.beginReply(to: message, contextID: model.messageActionContextID))
        let reply = model.composerReply.resolved
        let session = try begin(model)
        model.cancelMessageSelection(sessionID: session.id, contextID: session.contextID)
        XCTAssertEqual(model.draft, "ordinary reply"); XCTAssertEqual(model.composerReply.resolved, reply)
        let same = try begin(model)
        XCTAssertTrue(model.stageSelectedMessagesForward(destinationChatID: 10001, sessionID: same.id, contextID: same.contextID))
        XCTAssertNil(model.messageSelection.session); XCTAssertEqual(model.draft, "ordinary reply")
        XCTAssertEqual(model.composerReply.resolved, reply)
        XCTAssertEqual(model.composerForwardDisposition, .prepared)
    }
    func testUnknownLoadingAndSearchDoNotAdmitSelection() throws {
        let model = fixture(), context = model.messageActionContextID, window = try XCTUnwrap(model.historyWindowID)
        XCTAssertFalse(model.beginMessageSelection(messageID: "missing", contextID: context, windowID: window))
        XCTAssertFalse(model.beginMessageSelection(messageID: id(81), contextID: UUID(), windowID: window))
        XCTAssertFalse(model.beginMessageSelection(messageID: id(81), contextID: context, windowID: UUID()))
        model.search.messageQuery = "Тестовое сообщение"
        XCTAssertFalse(model.beginMessageSelection(messageID: id(81), contextID: context, windowID: window))
        model.search.messageQuery = ""
        let items = model.messages
        model.receiveMessages(items, requestID: window, previous: nil, next: nil, isLoading: true)
        XCTAssertFalse(model.beginMessageSelection(messageID: id(81), contextID: context, windowID: window))
        model.receiveMessages(items, requestID: window, previous: nil, next: nil, isLoading: false)
        XCTAssertTrue(model.beginMessageSelection(messageID: id(81), contextID: context, windowID: window))
    }
    func testChangedVisibleSourceInvalidatesFrozenSelectionWithoutReplacingIt() throws {
        let model = fixture(), session = try begin(model)
        var items = model.messages
        let index = try XCTUnwrap(items.firstIndex(where: { $0.id == id(85) }))
        let original = try XCTUnwrap(items[index].actionMetadata)
        items[index].actionMetadata = TelegramMessageActionMetadata(peerID: original.peerID,
            namespace: original.namespace, messageID: original.messageID, fingerprint: "changed-version",
            text: original.text, authorID: original.authorID, canReply: original.canReply,
            canEdit: original.canEdit, canForward: original.canForward,
            canDeleteLocally: original.canDeleteLocally, canDeleteForEveryone: original.canDeleteForEveryone)
        model.receiveMessages(items, requestID: try XCTUnwrap(model.historyWindowID), previous: nil, next: nil, isLoading: false)
        let changed = try XCTUnwrap(model.messageSelection.session)
        XCTAssertEqual(changed.sources, session.sources)
        XCTAssertNotEqual(changed.revision, session.revision)
        XCTAssertEqual(changed.invalidIDs.count, 1)
        XCTAssertFalse(changed.canForward)
        XCTAssertFalse(model.stageSelectedMessagesForward(destinationChatID: 10002,
            sessionID: session.id, contextID: session.contextID))
        XCTAssertNil(model.composerForwardIntent)
    }
    func testSelectionCancelPreservesActiveEditSessionAndOrdinaryInput() throws {
        let model = fixture(); model.draft = "ordinary unchanged"
        let message = try XCTUnwrap(model.messages.first(where: { model.actionSource(for: $0)?.canEdit == true }))
        let source = try XCTUnwrap(model.actionSource(for: message))
        XCTAssertTrue(model.beginMessageEdit(source: source, author: message.author, contextID: model.messageActionContextID))
        let edit = try XCTUnwrap(model.messageEditSession)
        let session = try begin(model)
        model.cancelMessageSelection(sessionID: session.id, contextID: session.contextID)
        XCTAssertEqual(model.messageEditSession, edit)
        XCTAssertEqual(model.draft, "ordinary unchanged")
    }
    func testProtectedSourcePreventsEntireBatchNoCommentOnlyFallback() throws {
        let model = fixture(); model.draft = "preserve comment"
        let session = try begin(model)
        XCTAssertTrue(model.toggleMessageSelection(messageID: id(120), sessionID: session.id, contextID: session.contextID,
            windowID: try XCTUnwrap(model.historyWindowID)))
        XCTAssertFalse(try XCTUnwrap(model.messageSelection.session).canForward)
        XCTAssertFalse(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: session.id, contextID: session.contextID))
        XCTAssertEqual(model.selectedChatID, 10001); XCTAssertEqual(model.draft, "preserve comment")
        XCTAssertNil(model.composerForwardIntent); XCTAssertNotNil(model.messageSelection.session)
    }
}
#endif
