import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

#if DEBUG
@MainActor final class TelegramExtendedSearchTests: XCTestCase {
    private func ready(_ search: TelegramSearchModel) async throws {
        for _ in 0..<150 {
            if search.messageStatus == .ready { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Search did not finish")
        throw WaitFailure.deadline
    }
    private enum WaitFailure: Error { case deadline }

    func testMediaOnlyAndSenderOnlyQueriesResetTheirCursorsAndRespectTopics() async throws {
        let model = TelegramModel.syntheticExtendedMessagesPreview()
        model.search.mediaFilter = .photos
        try await ready(model.search)
        XCTAssertEqual(model.search.messages.map(\.id), ["synthetic:10001:130"])
        XCTAssertEqual(model.search.totalMessages, 1)
        let photoContext = model.search.resultContextID
        model.search.mediaFilter = .files
        XCTAssertNotEqual(model.search.resultContextID, photoContext)
        try await ready(model.search)
        XCTAssertEqual(model.search.messages.map(\.id), ["synthetic:10001:129", "synthetic:10001:25"])
        model.search.clearMessageSearch()
        model.search.senderID = 999
        try await ready(model.search)
        XCTAssertEqual(model.search.totalMessages, 65)
        XCTAssertTrue(model.search.messages.allSatisfy { !$0.isOutgoing })
        model.search.selectChat(10001, threadID: 7)
        model.search.senderID = 1
        try await ready(model.search)
        XCTAssertEqual(model.search.totalMessages, 33)
        XCTAssertEqual(model.search.messages.map(\.id), stride(from: 130, through: 66, by: -2).map { "synthetic:10001:\($0)" })
    }

    func testOlderNavigationCrossesPageBoundaryAndNewerNeverWrapsOrLosesDraft() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        model.draft = "Черновик 😀"
        let search = model.search
        search.messageQuery = "Тестовое сообщение"
        try await ready(search)
        XCTAssertFalse(search.canSelectNewer)
        search.selectOlderResult()
        XCTAssertEqual(model.historyFocusID, "synthetic:10001:130")
        XCTAssertEqual(search.selectedResultIndex, 0)
        search.selectNewerResult()
        XCTAssertEqual(search.selectedResultIndex, 0)
        for _ in 0..<49 { search.selectOlderResult() }
        XCTAssertEqual(search.selectedResultIndex, 49)
        search.selectOlderResult()
        try await ready(search)
        XCTAssertEqual(search.messages.count, 100)
        XCTAssertEqual(search.selectedResultIndex, 50)
        XCTAssertEqual(model.historyFocusID, "synthetic:10001:80")
        XCTAssertFalse(search.showsResults)
        XCTAssertEqual(search.messageQuery, "Тестовое сообщение")
        XCTAssertEqual(model.draft, "Черновик 😀")
        search.selectNewerResult()
        XCTAssertEqual(model.historyFocusID, "synthetic:10001:81")
    }

    func testChangedFilterRejectsOldResultActivationAndInFlightOlderSelection() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        let search = model.search
        search.messageQuery = "Тестовое сообщение"
        try await ready(search)
        let oldContext = search.resultContextID
        for _ in 0..<50 { search.selectOlderResult() }
        search.selectOlderResult()
        search.mediaFilter = .photos
        try await ready(search)
        let focus = model.historyFocusID
        model.openSearchMessage(id: "synthetic:10001:130", contextID: oldContext)
        XCTAssertEqual(model.historyFocusID, focus)
        XCTAssertNil(search.selectedResultID)
        XCTAssertTrue(search.showsResults)
        XCTAssertEqual(search.messages.map(\.id), ["synthetic:10001:130"])
    }

    func testGlobalScopesAndChatFilterOpenExactTopicAndKeepOriginalDraft() async throws {
        let model = TelegramModel.syntheticExtendedMessagesPreview()
        model.draft = "Исходный черновик"
        let global = model.globalSearch
        global.scope = .channels
        global.mediaFilter = .photos
        try await ready(global)
        XCTAssertEqual(global.messages.map(\.id), ["synthetic:10005:130"])
        let context = global.resultContextID
        model.openGlobalSearchMessage(id: "synthetic:10005:130", contextID: context)
        XCTAssertEqual(model.selectedChatID, 10005)
        XCTAssertEqual(model.historyFocusID, "synthetic:10005:130")
        XCTAssertEqual(global.scope, .channels)
        global.scope = .groups
        try await ready(global)
        XCTAssertEqual(Set(global.messages.map { $0.actionMetadata?.peerID }), [10001, 10125])
        global.scopedChat = TelegramChat(id: 10001, title: "Форум · Макош QA", preview: "", unreadCount: 0)
        try await ready(global)
        XCTAssertEqual(global.messages.map(\.id), ["synthetic:10001:130"])
        model.openGlobalSearchMessage(id: "synthetic:10001:130", contextID: global.resultContextID)
        XCTAssertEqual(model.selectedChatID, 10001)
        XCTAssertEqual(model.selectedThreadID, 7)
        XCTAssertEqual(model.historyFocusID, "synthetic:10001:130")
        model.showForumAllMessages()
        XCTAssertEqual(model.draft, "Исходный черновик")
        let previousFocus = model.historyFocusID
        model.openGlobalSearchMessage(id: "synthetic:10001:130", contextID: context)
        XCTAssertEqual(model.historyFocusID, previousFocus)
    }

    func testRebindingGlobalSearchInvalidatesOldContextAndClearsMediaFilters() async throws {
        let search = TelegramSearchModel(global: true)
        search.useSyntheticPreview()
        search.mediaFilter = .photos
        try await ready(search)
        let old = search.resultContextID
        search.bind(account: nil)
        XCTAssertNotEqual(search.resultContextID, old)
        XCTAssertTrue(search.messages.isEmpty)
        XCTAssertEqual(search.mediaFilter, .all)
        XCTAssertNil(search.resultDestination(id: "synthetic:10001:130", contextID: old))
    }

    func testCalendarJumpSupersedesPendingOlderSelectionWithoutCancellingPagination() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        let search = model.search
        search.messageQuery = "Тестовое сообщение"
        try await ready(search)
        for _ in 0..<50 { search.selectOlderResult() }
        XCTAssertEqual(search.selectedResultIndex, 49)
        search.selectOlderResult()
        XCTAssertEqual(search.messageStatus, .loading)
        search.jumpToDate(try XCTUnwrap(search.messages.last).date)
        XCTAssertEqual(search.dateStatus, .ready)
        let dateFocus = model.historyFocusID
        XCTAssertNil(search.selectedResultID)
        try await ready(search)
        XCTAssertEqual(search.messages.count, 100)
        XCTAssertEqual(model.historyFocusID, dateFocus, "Late page completion must not replace a newer calendar navigation")
        XCTAssertNil(search.selectedResultID)
    }

    func testExplicitResultSelectionRejectsLateNativeDateCompletion() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        let search = model.search
        search.messageQuery = "Тестовое сообщение"
        try await ready(search)
        let context = search.resultContextID
        let lateDateID = "synthetic:10001:125"
        let index = try XCTUnwrap(search.messageIndex(id: lateDateID, inChat: 10001))
        let token = search.beginDateRequest()
        search.selectResult(id: "synthetic:10001:130", contextID: context)
        let chosenFocus = model.historyFocusID
        search.receiveDate(index: index, id: lateDateID, token: token, context: context)
        XCTAssertEqual(model.historyFocusID, chosenFocus)
        XCTAssertEqual(search.selectedResultID, "synthetic:10001:130")
        XCTAssertEqual(search.dateStatus, .idle)
    }

    func testScopedGlobalMigratedMatchKeepsSelectedModernChatAndOldNativeIndex() async throws {
        let model = TelegramModel.syntheticExtendedMessagesPreview()
        let search = model.globalSearch
        search.messageQuery = "Тестовое сообщение"
        try await ready(search)
        let message = try XCTUnwrap(search.messages.first)
        let modern = TelegramChat(id: 10001, title: "Выбранный форум", preview: "", unreadCount: 0)
        let oldID = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(55))
        let oldChat = TelegramChat(id: oldID.toInt64(), title: "Старая группа", preview: "", unreadCount: 0)
        let oldIndex = MessageIndex(id: MessageId(peerId: oldID, namespace: Namespaces.Message.Cloud, id: 125), timestamp: 1700000000)
        search.scopedChat = modern
        let token = try XCTUnwrap(search.messageRequestID), context = search.resultContextID
        search.receiveMessages([message], indexes: [message.id: oldIndex], destinations: [message.id: oldChat], threads: [:],
            cursor: .synthetic(1), total: 1, completed: true, failed: false, requestID: token)
        let destination = try XCTUnwrap(search.resultDestination(id: message.id, contextID: context))
        XCTAssertEqual(destination.0, modern)
        XCTAssertEqual(destination.1, oldIndex, "Migrated native indexes must not be rewritten to another peer")
        model.openGlobalSearchMessage(id: message.id, contextID: context)
        XCTAssertEqual(model.selectedChatID, modern.id)
        XCTAssertNil(model.selectedThreadID)
        XCTAssertEqual(search.messageQuery, "Тестовое сообщение")
        search.bind(account: nil)
    }
}
#endif
