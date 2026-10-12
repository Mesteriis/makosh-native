#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramForumSearchTests: XCTestCase {
    func testChangingOnlyTopicInvalidatesResultsAndDoesNotSearchOtherThreads() async throws {
        let search = TelegramSearchModel()
        search.useSyntheticPreview()
        search.selectChat(10001)
        search.messageQuery = "Тестовое сообщение"
        try await ready(search)
        XCTAssertEqual(search.messages.count, 50)
        search.selectChat(10001, threadID: 7)
        XCTAssertTrue(search.messages.isEmpty)
        XCTAssertEqual(search.messageQuery, "")
        search.messageQuery = "Тестовое сообщение"
        try await ready(search)
        XCTAssertTrue(search.messages.isEmpty, "Ordinary synthetic messages must not appear in another thread")
        XCTAssertEqual(search.totalMessages, 0)
        search.selectChat(10001)
        search.messageQuery = "Тестовое сообщение"
        try await ready(search)
        XCTAssertEqual(search.totalMessages, 130)
    }

    private func ready(_ search: TelegramSearchModel) async throws {
        for _ in 0..<150 {
            if search.messageStatus == .ready { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Search did not finish")
    }
}
#endif
