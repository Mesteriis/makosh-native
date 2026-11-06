import Foundation
import MakoshCore
import XCTest
@testable import MakoshAI

final class AIContextModelTests: XCTestCase {
    func testLegacyConversationDecodesWithoutCards() throws {
        let json = #"{"id":"5A0B5C46-0000-4000-8000-000000000001","title":"t","createdAt":0,"updatedAt":0}"#
        let value = try JSONDecoder().decode(AIConversation.self, from: Data(json.utf8))
        XCTAssertNil(value.anchor)
        XCTAssertEqual(value.cards, [])
        XCTAssertTrue(value.searchMyData)
    }

    func testRoleAssignmentDecodesWithoutContextTokens() throws {
        let json = #"{"role":"chat","connectionID":"5A0B5C46-0000-4000-8000-000000000001","model":"m"}"#
        let value = try JSONDecoder().decode(AIRoleAssignment.self, from: Data(json.utf8))
        XCTAssertNil(value.contextTokens)
        let again = try JSONDecoder().decode(
            AIRoleAssignment.self,
            from: JSONEncoder().encode(AIRoleAssignment(role: .chat, connectionID: value.connectionID, model: "m", contextTokens: 200_000)))
        XCTAssertEqual(again.contextTokens, 200_000)
    }

    func testLegacyVersionDecodesWithoutContext() throws {
        let json = #"{"id":"5A0B5C46-0000-4000-8000-000000000002","text":"x","state":"complete","createdAt":0}"#
        XCTAssertEqual(try JSONDecoder().decode(AIMessageVersion.self, from: Data(json.utf8)).context, [])
    }

    func testCardRoundTripsAndHasStableID() throws {
        let card = AIContextCard.chat(service: "telegram", accountID: "1", chatID: "2", title: "Мария", range: .standard)
        let again = try JSONDecoder().decode(AIContextCard.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(again, card)
        XCTAssertEqual(card.id, "chat:telegram:1:2")
        XCTAssertEqual(AIContextCard.letter(id: "L", title: "Тема").id, "letter:L")
        let range = AIContextCard.chat(
            service: "telegram", accountID: "1", chatID: "2", title: "Мария", range: .between(Date(timeIntervalSince1970: 0), .now))
        XCTAssertEqual(range.id, card.id, "changing the period keeps the same card")
    }

    func testFileCardIDsIgnorePages() {
        let record = UUID(uuidString: "5A0B5C46-0000-4000-8000-00000000000A")!,
            connection = UUID(uuidString: "5A0B5C46-0000-4000-8000-00000000000B")!
        XCTAssertEqual(
            AIContextCard.file(source: .archive(recordID: record), title: "a", pages: 1...3).id,
            "file:archive:5a0b5c46-0000-4000-8000-00000000000a")
        XCTAssertEqual(
            AIContextCard.file(source: .paperless(connectionID: connection, documentID: 12), title: "b", pages: nil).id,
            "file:paperless:5a0b5c46-0000-4000-8000-00000000000b:12")
        XCTAssertEqual(
            AIContextCard.file(source: .staged(id: record), title: "c", pages: nil).id, "file:staged:5a0b5c46-0000-4000-8000-00000000000a")
        XCTAssertEqual(AIContextCard.file(source: .staged(id: record), title: "c", pages: nil).title, "c")
    }

    func testFileCardRoundTripsAndOldConversationsDecode() throws {
        let card = AIContextCard.file(source: .paperless(connectionID: UUID(), documentID: 7), title: "Договор", pages: 2...5)
        XCTAssertEqual(try JSONDecoder().decode(AIContextCard.self, from: JSONEncoder().encode(card)), card)
        var conversation = AIConversation(title: "t", createdAt: .now, updatedAt: .now)
        conversation.cards = [card, .letter(id: "L", title: "Тема")]
        XCTAssertEqual(try JSONDecoder().decode(AIConversation.self, from: JSONEncoder().encode(conversation)), conversation)
        let old =
            #"{"id":"5A0B5C46-0000-4000-8000-000000000001","title":"t","createdAt":0,"updatedAt":0,"cards":[{"letter":{"id":"L","title":"Тема"}}]}"#
        XCTAssertEqual(try JSONDecoder().decode(AIConversation.self, from: Data(old.utf8)).cards, [.letter(id: "L", title: "Тема")])
    }

    func testConversationWithCardsRoundTrips() throws {
        let card = AIContextCard.chat(service: "whatsapp", accountID: "a", chatID: "c", title: "Чат", range: .lastDays(7))
        var conversation = AIConversation(title: "t", createdAt: .now, updatedAt: .now)
        conversation.anchor = card
        conversation.cards = [card, .contact(id: UUID(), title: "Иван")]
        let again = try JSONDecoder().decode(AIConversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertEqual(again, conversation)
    }
}
