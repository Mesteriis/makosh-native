#if DEBUG
import XCTest
@testable import MakoshTelegram

final class TelegramForumSyntheticPagesTests: XCTestCase {
    func testTopicWindowsPageOnlyWithinTheirOwnThread() throws {
        let pages = TelegramSyntheticPages(forum: true)
        let design = pages.messages(chatID: 10001, anchor: nil, threadID: 7)
        XCTAssertEqual(design.items.count, 50)
        XCTAssertTrue(design.items.allSatisfy { $0.actionMetadata?.threadID == 7 })
        let older = pages.messages(chatID: 10001, anchor: design.previous, threadID: 7)
        XCTAssertEqual(older.items.count, 15)
        XCTAssertTrue(older.items.allSatisfy { $0.actionMetadata?.threadID == 7 })
        XCTAssertNil(older.previous)
        let general = pages.messages(chatID: 10001, anchor: nil, threadID: 1)
        XCTAssertEqual(general.items.last?.actionMetadata?.messageID, 65)
        XCTAssertTrue(general.items.allSatisfy { $0.actionMetadata?.threadID == 1 })
        XCTAssertTrue(pages.messages(chatID: 10001, anchor: nil, threadID: 99).items.isEmpty)
    }
    func testSearchKeepsTopicScopeAndAllMessagesStillContainsBothTopics() throws {
        let pages = TelegramSyntheticPages(forum: true)
        XCTAssertEqual(pages.searchMessages(chatID: 10001, query: "Тестовое сообщение", threadID: 1).items.count, 65)
        XCTAssertEqual(pages.searchMessages(chatID: 10001, query: "Тестовое сообщение", threadID: 7).items.count, 65)
        XCTAssertEqual(pages.searchMessages(chatID: 10001, query: "Тестовое сообщение").items.count, 130)
        XCTAssertTrue(TelegramSyntheticPages().messages(chatID: 10001, anchor: nil).items.allSatisfy {
            $0.actionMetadata?.threadID == nil
        })
    }
}
#endif
