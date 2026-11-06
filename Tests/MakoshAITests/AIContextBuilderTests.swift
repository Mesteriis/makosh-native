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

    func testDocumentMaterialPrintsPagesAndFlags() throws {
        let card = AIContextCard.file(source: .archive(recordID: UUID()), title: "Договор", pages: 2...3)
        let document = AIContextDocument(
            pages: ["Пункт 1", "Пункт 2"], pageCount: 5, selected: 2...3, paginated: true, recognized: true, truncatedOCR: false,
            source: "archive")
        let material = AIContextMaterial.document(card, document)
        XCTAssertEqual(material.available, 5)
        XCTAssertEqual(material.lines, [])
        let text = try XCTUnwrap(AIContextBuilder.turn([material], history: [], budgetTokens: 10_000)).text
        XCTAssertTrue(text.contains("=== Файл «Договор» (страницы 2–3 из 5, распознано со скана) ==="), text)
        XCTAssertTrue(text.contains("--- стр. 2 ---\nПункт 1"), text)
        XCTAssertTrue(text.contains("--- стр. 3 ---\nПункт 2"), text)
        XCTAssertTrue(text.contains("файлы"), "the system turn names files among the sources")
        XCTAssertFalse(text.contains("распознаны первые"))
    }

    func testUnpaginatedDocumentPrintsParts() throws {
        let card = AIContextCard.file(source: .staged(id: UUID()), title: "Заметки.txt", pages: nil)
        let document = AIContextDocument(
            pages: ["а", "б"], pageCount: 2, selected: 1...2, paginated: false, recognized: false, truncatedOCR: true, source: "staged")
        let text = try XCTUnwrap(AIContextBuilder.turn([.document(card, document)], history: [], budgetTokens: 10_000)).text
        XCTAssertTrue(text.contains("=== Файл «Заметки.txt» (части 1–2 из 2) ==="), text)
        XCTAssertTrue(text.contains("--- часть 1 ---\nа"), text)
        XCTAssertTrue(text.contains("(распознаны первые \(AIContextDocument.ocrPageLimit) страниц)"), text)
    }

    func testNoCardsMeansNoTurn() throws { XCTAssertNil(try AIContextBuilder.turn([], history: [], budgetTokens: 10)) }
}
