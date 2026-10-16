import XCTest
@testable import MakoshTelegram

#if DEBUG
final class TelegramPaginationModelTests: XCTestCase {
    @MainActor func testChatsTraverseBeyondFiftyAndRetainSelectionAndDraft() async throws {
        let model = TelegramModel.syntheticPreview()
        let first = try XCTUnwrap(model.chats.first)
        model.selectedChatID = first.id
        model.draft = "Незавершённый текст"
        model.loadOlderChats()
        XCTAssertEqual(model.chats.first?.title, "Тестовый диалог 51")
        XCTAssertEqual(model.selectedChat, first)
        XCTAssertEqual(model.draft, "Незавершённый текст")
        model.loadOlderChats()
        XCTAssertEqual(model.chats.count, 25)
        XCTAssertFalse(model.chatPage.canLoadPrevious)
        model.loadNewerChats()
        XCTAssertEqual(model.chats.first?.title, "Тестовый диалог 51")
        model.showLatestChats()
        XCTAssertEqual(model.chats.first, first)
        XCTAssertTrue(model.chatPage.isAtLatest)
    }

    @MainActor func testArchiveAndCrossChatDraftsStayIndependent() async throws {
        let model = TelegramModel.syntheticPreview()
        let inbox = try XCTUnwrap(model.chats.first)
        model.selectedChatID = inbox.id
        model.draft = "Черновик входящего диалога"
        model.chatFolder = .archive
        XCTAssertEqual(model.selectedChat, inbox)
        let archive = try XCTUnwrap(model.chats.first)
        XCTAssertNotEqual(archive.id, inbox.id)
        model.selectedChatID = archive.id
        XCTAssertEqual(model.draft, "")
        model.draft = "Черновик архива"
        model.loadOlderChats()
        XCTAssertEqual(model.chats.count, 15)
        model.selectedChatID = inbox.id
        XCTAssertEqual(model.draft, "Черновик входящего диалога")
        model.selectedChatID = archive.id
        XCTAssertEqual(model.draft, "Черновик архива")
    }

    @MainActor func testHistoryTraversesBothWaysAndLatest() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let latest = model.messages
        XCTAssertTrue(latest.first?.text.hasPrefix("Тестовое сообщение 81 ") == true)
        model.loadOlderMessages()
        XCTAssertTrue(model.messages.first?.text.hasPrefix("Тестовое сообщение 31 ") == true)
        model.loadOlderMessages()
        XCTAssertEqual(model.messages.count, 30)
        XCTAssertFalse(model.historyPage.canLoadPrevious)
        model.loadNewerMessages()
        XCTAssertTrue(model.messages.first?.text.hasPrefix("Тестовое сообщение 31 ") == true)
        model.showLatestMessages()
        XCTAssertEqual(model.messages, latest)
        XCTAssertTrue(model.historyPage.isAtLatest)
    }

    @MainActor func testDelayedEmissionsCannotReplaceNewWindowAndEmptyLoadingRetainsData() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let stale = try XCTUnwrap(model.historyWindowID)
        model.loadOlderMessages()
        let current = try XCTUnwrap(model.historyWindowID)
        let messages = model.messages
        model.receiveMessages([], requestID: stale, previous: nil, next: nil, isLoading: false)
        XCTAssertEqual(model.messages, messages)
        model.receiveMessages([], requestID: current, previous: nil, next: nil, isLoading: true, hasPreviousGap: true)
        XCTAssertEqual(model.messages, messages)
        XCTAssertTrue(model.historyPage.isLoading)
        model.receiveMessages([], requestID: current, previous: nil, next: nil, isLoading: false)
        XCTAssertEqual(model.messages, [])
        XCTAssertFalse(model.historyPage.isLoading)
    }

    @MainActor func testPreviewCannotSendOrOpenSavedAccountAndDisconnectRejectsCallbacks() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let history = try XCTUnwrap(model.historyWindowID)
        let chats = try XCTUnwrap(model.chatWindowID)
        model.draft = "Не отправлять"
        XCTAssertFalse(model.sendMessage(model.draft))
        XCTAssertEqual(model.draft, "Не отправлять")
        model.disconnect()
        model.connect()
        model.connect(apiID: "1", apiHash: String(repeating: "a", count: 32))
        XCTAssertEqual(model.phase, .configuration)
        XCTAssertTrue(model.isSyntheticPreview)
        model.receiveMessages([], requestID: history, previous: nil, next: nil, isLoading: true)
        model.receiveChats([], requestID: chats, previous: nil, next: nil, isLoading: true)
        XCTAssertFalse(model.historyPage.isLoading)
        XCTAssertFalse(model.chatPage.isLoading)
    }
}
#endif
