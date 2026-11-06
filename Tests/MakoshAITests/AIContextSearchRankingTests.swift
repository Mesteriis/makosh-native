import Foundation
import MakoshCore
import XCTest
@testable import MakoshAI

final class AIContextSearchRankingTests: XCTestCase {
    private func chat(_ title: String) -> AIContextSuggestion {
        AIContextSuggestion(
            card: .chat(service: "telegram", accountID: "1", chatID: title, title: title, range: .standard), subtitle: "Telegram")
    }

    func testPrefixBeatsSubstring() {
        let items = [chat("Команда Мария"), chat("Мария Иванова")]
        XCTAssertEqual(AIContextRanking.rank(items, query: "мар", limit: 10).map(\.card.title), ["Мария Иванова", "Команда Мария"])
    }

    func testWordPrefixBeatsInnerSubstring() {
        let items = [chat("Тамара"), chat("Команда Мария")]
        XCTAssertEqual(AIContextRanking.rank(items, query: "мар", limit: 10).map(\.card.title), ["Команда Мария", "Тамара"])
    }

    func testCaseAndYoInsensitive() {
        let items = [chat("Семён"), chat("Петр")]
        XCTAssertEqual(AIContextRanking.rank(items, query: "СЕМЕН", limit: 10).map(\.card.title), ["Семён"])
    }

    func testLimitRespectedAndNonMatchesDropped() {
        let items = (1...20).map { chat("Чат \($0)") } + [chat("Другое")]
        let ranked = AIContextRanking.rank(items, query: "чат", limit: 5)
        XCTAssertEqual(ranked.count, 5)
        XCTAssertFalse(ranked.contains { $0.card.title == "Другое" })
        XCTAssertEqual(ranked.map(\.card.title), ["Чат 1", "Чат 2", "Чат 3", "Чат 4", "Чат 5"], "stable order among equals")
    }

    func testFilesRankWithChatsAndMatchBySubtitle() {
        let file = AIContextSuggestion(
            card: .file(source: .archive(recordID: UUID()), title: "Счёт за ноябрь.pdf", pages: nil), subtitle: "Файл · Почта")
        let paperless = AIContextSuggestion(
            card: .file(source: .paperless(connectionID: UUID(), documentID: 3), title: "Договор аренды", pages: nil), subtitle: "Paperless"
        )
        let items = [chat("Мария"), file, paperless]
        XCTAssertEqual(AIContextRanking.rank(items, query: "счет", limit: 10).map(\.card.title), ["Счёт за ноябрь.pdf"])
        XCTAssertEqual(AIContextRanking.rank(items, query: "paperless", limit: 10).map(\.card.title), ["Договор аренды"])
        XCTAssertEqual(AIContextRanking.rank(items, query: "", limit: 10).count, 3)
    }

    func testEmptyQueryKeepsOrder() {
        let items = [chat("Б"), chat("А")]
        XCTAssertEqual(AIContextRanking.rank(items, query: " ", limit: 10).map(\.card.title), ["Б", "А"])
    }
}
