#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramSyntheticAlbumWorkflowTests: XCTestCase {
    private func fixture() -> TelegramModel {
        let model = TelegramModel.syntheticPreview(albums: true)
        model.selectedChatID = 10003
        model.draft = "ordinary album input"
        return model
    }
    private func select(_ model: TelegramModel, number: Int) throws -> TelegramMessageSelectionSession {
        XCTAssertTrue(model.beginMessageSelection(messageID: "synthetic:10003:\(number)", contextID: model.messageActionContextID,
            windowID: try XCTUnwrap(model.historyWindowID)))
        return try XCTUnwrap(model.messageSelection.session)
    }

    func testPartialAlbumForwardResolvesSameVersionsAfterRecipientChange() throws {
        let model = fixture(), first = try select(model, number: 127)
        XCTAssertTrue(model.toggleMessageSelection(messageID: "synthetic:10003:128", sessionID: first.id,
            contextID: first.contextID, windowID: try XCTUnwrap(model.historyWindowID)))
        let selected = try XCTUnwrap(model.messageSelection.session)
        XCTAssertTrue(model.stageSelectedMessagesForward(destinationChatID: 10004, sessionID: selected.id,
            contextID: selected.contextID, expectedRevision: selected.revision))
        XCTAssertEqual(model.composerForwardIntent?.sources.map(\.messageID), [127, 128])
        XCTAssertEqual(model.composerForward.phase, .ready)
        XCTAssertEqual(model.composerForward.previews.map(\.id), ["synthetic:10003:127", "synthetic:10003:128"])
        XCTAssertEqual(model.composerForward.previews.map(\.author), ["Синтетический альбом", "Синтетический альбом"])
        model.selectedChatID = 10003
        XCTAssertEqual(model.draft, "ordinary album input")
    }

    func testAlbumCopyResolvesCurrentFixtureWithoutLosingAuthorOrCaption() throws {
        let model = fixture(), selected = try select(model, number: 127)
        var copied: String?
        XCTAssertTrue(model.copySelectedMessages(sessionID: selected.id, contextID: selected.contextID,
            expectedRevision: selected.revision) { copied = $0 })
        let text = try XCTUnwrap(copied)
        XCTAssertTrue(text.contains("Синтетический альбом"))
        XCTAssertTrue(text.contains("Тестовое сообщение 127 • диалог 10003"))
        XCTAssertFalse(text.contains("Тестовое сообщение 126"))
    }

    func testAlbumReplyResolvesCurrentFixtureSource() throws {
        let model = fixture(), message = try XCTUnwrap(model.messages.first { $0.id == "synthetic:10003:127" })
        XCTAssertTrue(model.beginReply(to: message, contextID: model.messageActionContextID))
        model.selectedChatID = 10004
        model.selectedChatID = 10003
        let reply = try XCTUnwrap(model.composerReply.resolved)
        XCTAssertEqual(reply.author, "Синтетический альбом")
        XCTAssertEqual(reply.source.fingerprint, "synthetic-version-1-10003-127-album")
    }

    func testAlbumShiftRangeUsesCurrentVersionsInsteadOfInvalidatingMembers() throws {
        let model = fixture(), selected = try select(model, number: 130)
        XCTAssertTrue(model.toggleMessageSelection(messageID: "synthetic:10003:122", sessionID: selected.id,
            contextID: selected.contextID, windowID: try XCTUnwrap(model.historyWindowID), extendingRange: true))
        let range = try XCTUnwrap(model.messageSelection.session)
        XCTAssertEqual(range.sources.map(\.messageID), [122, 123, 124, 125, 126, 127, 128, 129, 130])
        XCTAssertTrue(range.canForward)
        XCTAssertEqual(range.sources.first { $0.messageID == 127 }?.fingerprint, "synthetic-version-1-10003-127-album")
    }

    func testAlbumSavedForwardAcceptsOnlyCapturedSelectionInOfflineFixture() throws {
        let model = fixture(), selected = try select(model, number: 127)
        XCTAssertTrue(model.forwardSelectedMessagesToSaved(sessionID: selected.id, contextID: selected.contextID,
            expectedRevision: selected.revision))
        XCTAssertEqual(model.savedMessagesForward.phase, .queued)
        XCTAssertNil(model.messageSelection.session)
        XCTAssertEqual(model.selectedChatID, 10003)
        XCTAssertEqual(model.draft, "ordinary album input")
    }
}
#endif
