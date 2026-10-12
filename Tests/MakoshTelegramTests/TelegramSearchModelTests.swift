import Foundation
import XCTest
@testable import MakoshTelegram

#if DEBUG
@MainActor
final class TelegramSearchModelTests: XCTestCase {
    private enum WaitFailure: Error { case deadline }

    private func eventually(file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Synthetic search did not reach the expected state within two seconds", file: file, line: line)
                throw WaitFailure.deadline
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func selectedModel() throws -> TelegramModel {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        return model
    }

    func testLocalSearchFindsChatsBeyondVisibleWindowAndRespectsArchive() async throws {
        let model = TelegramModel.syntheticPreview()
        XCTAssertFalse(model.chats.contains { $0.title == "Тестовый диалог 125" })
        model.search.chatQuery = "диалог 125"
        try await eventually { model.search.chatStatus == .ready }
        let found = try XCTUnwrap(model.search.chats.first)
        XCTAssertEqual(model.search.chats.count, 1)
        XCTAssertEqual(found.title, "Тестовый диалог 125")
        model.selectedChatID = found.id
        XCTAssertEqual(model.selectedChat, found)
        model.chatFolder = .archive
        model.search.chatQuery = "диалог 65"
        try await eventually { model.search.chatStatus == .ready }
        XCTAssertEqual(model.search.chats.count, 1)
        XCTAssertEqual(model.search.chats.first?.title, "Тестовый диалог 65")
        XCTAssertNotEqual(model.search.chats.first?.id, found.id)
        model.search.chatQuery = "диалог 125"
        try await eventually { model.search.chatStatus == .ready }
        XCTAssertTrue(model.search.chats.isEmpty)
    }

    func testOpenSearchMessageLoadsFocusedHistoryWithoutLosingComposer() async throws {
        let model = try selectedModel()
        model.draft = "Сохранить несохранённый текст"
        model.search.messageQuery = "сообщение 125 "
        try await eventually { model.search.messageStatus == .ready }
        let result = try XCTUnwrap(model.search.messages.first)
        XCTAssertEqual(model.search.messages.count, 1)
        XCTAssertNotNil(model.search.messageIndex(id: result.id, inChat: model.selectedChatID))
        XCTAssertNil(model.search.messageIndex(id: result.id, inChat: -42))
        let latestWindow = model.messages.map(\.id)
        model.openSearchMessage(id: result.id)
        XCTAssertNotEqual(model.messages.map(\.id), latestWindow)
        XCTAssertTrue(model.messages.contains { $0.id == result.id })
        XCTAssertEqual(model.historyFocusID, result.id)
        XCTAssertEqual(model.draft, "Сохранить несохранённый текст")
        XCTAssertEqual(model.search.messageQuery, "сообщение 125 ", "History navigation must preserve the reference search session")
        XCTAssertEqual(model.search.messageStatus, .ready)
    }

    func testMessageSearchAccumulatesFiftyOneHundredAndOneHundredThirtyWithoutDuplicates() async throws {
        let model = try selectedModel()
        model.search.messageQuery = "Тестовое сообщение"
        try await eventually { model.search.messageStatus == .ready }
        XCTAssertEqual(model.search.messages.count, 50)
        XCTAssertEqual(model.search.totalMessages, 130)
        let firstIDs = model.search.messages.map(\.id)
        model.search.loadMoreMessages()
        let pageRequest = model.search.messageRequestID
        model.search.loadMoreMessages()
        XCTAssertEqual(model.search.messageRequestID, pageRequest)
        try await eventually { model.search.messageStatus == .ready }
        XCTAssertEqual(model.search.messages.count, 100)
        XCTAssertEqual(Array(model.search.messages.prefix(50).map(\.id)), firstIDs)
        model.search.loadMoreMessages()
        try await eventually { model.search.messageStatus == .ready }
        XCTAssertEqual(model.search.messages.count, 130)
        XCTAssertEqual(Set(model.search.messages.map(\.id)).count, 130)
        XCTAssertFalse(model.search.canLoadMoreMessages)
        let completedRequest = model.search.messageRequestID
        model.search.loadMoreMessages()
        XCTAssertEqual(model.search.messageRequestID, completedRequest)
    }

    func testHistoryFocusWaitsForReadyCurrentWindowEvenWhenRetainedMessagesContainTarget() async throws {
        let model = try selectedModel()
        model.search.messageQuery = "сообщение 125 "
        try await eventually { model.search.messageStatus == .ready }
        let result = try XCTUnwrap(model.search.messages.first)
        model.openSearchMessage(id: result.id)
        let request = try XCTUnwrap(model.historyWindowID)
        let retained = model.messages
        model.receiveMessages(retained, requestID: request, previous: nil, next: nil, isLoading: true)
        XCTAssertEqual(model.historyFocusID, result.id)
        XCTAssertNil(model.readyHistoryFocusID)
        model.receiveMessages(retained, requestID: UUID(), previous: nil, next: nil, isLoading: false)
        XCTAssertNil(model.readyHistoryFocusID)
        model.receiveMessages(retained, requestID: request, previous: nil, next: nil, isLoading: false)
        XCTAssertEqual(model.readyHistoryFocusID, result.id)
        model.clearHistoryFocus()
        XCTAssertNil(model.readyHistoryFocusID)
    }

    func testFirstFailureRetriesInitialPageAndSuccessfulZeroIsReady() async throws {
        let model = try selectedModel()
        model.search.failNextSyntheticMessageSearch()
        model.search.messageQuery = "Тестовое сообщение"
        try await eventually { model.search.messageStatus == .failed }
        XCTAssertTrue(model.search.messages.isEmpty)
        XCTAssertEqual(model.search.totalMessages, 0)
        XCTAssertTrue(model.search.canRetryMessages)
        XCTAssertFalse(model.search.canLoadMoreMessages)
        model.search.retryMessages()
        try await eventually { model.search.messageStatus == .ready }
        XCTAssertEqual(model.search.messages.count, 50)
        XCTAssertTrue(model.search.canLoadMoreMessages)
        model.search.messageQuery = "synthetic-no-match-unique"
        try await eventually { model.search.messageStatus == .ready }
        XCTAssertTrue(model.search.messages.isEmpty)
        XCTAssertEqual(model.search.totalMessages, 0)
        XCTAssertFalse(model.search.canRetryMessages)
        XCTAssertFalse(model.search.canLoadMoreMessages)
    }

    func testLaterFailurePreservesResultsAndRetryUsesLastSuccessfulCursor() async throws {
        let model = try selectedModel()
        model.search.messageQuery = "Тестовое сообщение"
        try await eventually { model.search.messageStatus == .ready }
        let first = model.search.messages
        model.search.failNextSyntheticMessageSearch()
        model.search.loadMoreMessages()
        try await eventually { model.search.messageStatus == .failed }
        XCTAssertEqual(model.search.messages, first)
        XCTAssertEqual(model.search.totalMessages, 130)
        XCTAssertTrue(model.search.canRetryMessages)
        model.search.retryMessages()
        let retry = model.search.messageRequestID
        model.search.retryMessages()
        XCTAssertEqual(model.search.messageRequestID, retry)
        try await eventually { model.search.messageStatus == .ready }
        XCTAssertEqual(model.search.messages.count, 100)
        XCTAssertEqual(Array(model.search.messages.prefix(50)), first)
        XCTAssertEqual(Set(model.search.messages.map(\.id)).count, 100)
    }

    func testRapidQueryReplacementRejectsOldChatEmissionAndUsesLatestMessageQuery() async throws {
        let model = try selectedModel()
        model.search.chatQuery = "диалог 125"
        let stale = try XCTUnwrap(model.search.chatRequestID)
        model.search.chatQuery = "диалог 124"
        model.search.receiveChats([], requestID: stale)
        XCTAssertEqual(model.search.chatStatus, .loading)
        model.search.messageQuery = "сообщение 125 "
        let oldMessageRequest = model.search.messageRequestID
        model.search.messageQuery = "сообщение 124 "
        XCTAssertNotEqual(model.search.messageRequestID, oldMessageRequest)
        try await eventually { model.search.chatStatus == .ready && model.search.messageStatus == .ready }
        XCTAssertEqual(model.search.chats.first?.title, "Тестовый диалог 124")
        XCTAssertEqual(model.search.messages.count, 1)
        XCTAssertTrue(model.search.messages[0].text.hasPrefix("Тестовое сообщение 124 "))
    }

    func testChatSwitchAndDisconnectInvalidatePendingDebounce() async throws {
        let model = try selectedModel()
        model.search.messageQuery = "Тестовое сообщение"
        let old = model.search.messageRequestID
        model.selectedChatID = try XCTUnwrap(model.chats.dropFirst().first).id
        XCTAssertNil(model.search.messageRequestID)
        XCTAssertEqual(model.search.messageStatus, .idle)
        model.search.messageQuery = "сообщение 125 "
        XCTAssertNotEqual(model.search.messageRequestID, old)
        try await eventually { model.search.messageStatus == .ready }
        XCTAssertEqual(model.search.messages.count, 1)
        let selected = try XCTUnwrap(model.selectedChatID)
        XCTAssertTrue(model.search.messages[0].id.hasPrefix("synthetic:\(selected):"))
        model.search.chatQuery = "диалог 125"
        model.search.messageQuery = "Тестовое сообщение"
        model.disconnect()
        XCTAssertNil(model.search.chatRequestID)
        XCTAssertNil(model.search.messageRequestID)
        // Let both obsolete debounce deadlines elapse, without opening an account.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.search.chatStatus, .idle)
        XCTAssertEqual(model.search.messageStatus, .idle)
        XCTAssertTrue(model.search.chats.isEmpty)
        XCTAssertTrue(model.search.messages.isEmpty)
        XCTAssertEqual(model.phase, .configuration)
    }
}
#endif
