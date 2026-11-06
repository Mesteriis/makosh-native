import Foundation
import MakoshCore
import XCTest
@testable import MakoshAI

final class AIContextBuilderTests: XCTestCase {
    private let chat = AIContextCard.chat(service: "telegram", accountID: "1", chatID: "2", title: "Мария", range: .standard)

    func testTurnListsEveryCardWithItsLines() throws {
        let material = AIContextMaterial(
            card: chat, lines: [.init(author: "Мария", isOutgoing: false, date: Date(timeIntervalSince1970: 0), text: "привет")],
            hiddenForbidden: 0, hiddenProtected: 0, available: 1, requested: 200)
        let letter = AIContextMaterial(
            card: .letter(id: "L", title: "Счёт"),
            lines: [.init(author: "bank@example.test", isOutgoing: false, date: .now, text: "оплатить")],
            hiddenForbidden: 0, hiddenProtected: 0, available: 1, requested: nil)
        let turn = try XCTUnwrap(AIContextBuilder.turn([material, letter], history: [], budgetTokens: 100_000))
        XCTAssertEqual(turn.author, .system)
        XCTAssertTrue(turn.text.contains("Мария"))
        XCTAssertTrue(turn.text.contains("привет"))
        XCTAssertTrue(turn.text.contains("Счёт"))
        XCTAssertTrue(turn.text.contains("оплатить"))
        XCTAssertLessThan(
            try XCTUnwrap(turn.text.range(of: "привет")).lowerBound, try XCTUnwrap(turn.text.range(of: "оплатить")).lowerBound)
    }

    func testOutgoingLinesAreMarkedAsTheUser() throws {
        let material = AIContextMaterial(
            card: chat, lines: [.init(author: "Я", isOutgoing: true, date: .now, text: "ок")], hiddenForbidden: 0, hiddenProtected: 0,
            available: 1, requested: 200)
        XCTAssertTrue(try XCTUnwrap(AIContextBuilder.turn([material], history: [], budgetTokens: 1_000)).text.contains("пользователь"))
    }

    func testOverBudgetThrowsWithTokenNumbers() {
        // 1 000 Cyrillic characters ≈ 400 tokens; the history adds its own share.
        let long = AIContextLine(author: "A", isOutgoing: false, date: .now, text: String(repeating: "я", count: 1_000))
        let material = AIContextMaterial(
            card: .letter(id: "L", title: "T"), lines: [long], hiddenForbidden: 0, hiddenProtected: 0, available: 1, requested: nil)
        let history = [AIChatTurn(author: .user, text: String(repeating: "q", count: 400))]
        XCTAssertThrowsError(try AIContextBuilder.turn([material], history: history, budgetTokens: 100)) { error in
            guard case .contextTooLarge(let tokens, 100)? = error as? AIFailure else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(tokens, 500, "cards plus history, in tokens")
        }
        XCTAssertNoThrow(try AIContextBuilder.turn([material], history: history, budgetTokens: 2_000))
    }

    func testNoCardsMeansNoTurn() throws { XCTAssertNil(try AIContextBuilder.turn([], history: [], budgetTokens: 10)) }
}
