import MakoshCore
import XCTest
@testable import MakoshAI

func aiItem(
    _ sequence: Int64, chat: String = "c", text: String, author: String? = "peer", outgoing: Bool = false, removed: Bool = false,
    service: String = "telegram"
) -> AIIndexItem {
    AIIndexItem(
        sequence: sequence, identity: MessageArchiveIdentity(service: service, accountID: "acc", conversationID: chat, messageID: "\(sequence)"),
        scope: .conversation(service: service, accountID: "acc", conversationID: chat),
        author: author.map { ServiceIdentity(service: service, accountID: "acc", externalID: $0) }, isOutgoing: outgoing,
        date: Date(timeIntervalSince1970: 1_000 + Double(sequence)), title: "", text: text, removed: removed)
}

final class AIChunkerTests: XCTestCase {
    func testChatWindowsOverlap() {
        let items = (1...14).map { aiItem(Int64($0), text: "m\($0)") }
        let chunks = AIChunker.chunks(items, generation: 1) { _ in true }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].messages.map(\.messageID), (1...8).map(String.init))
        XCTAssertEqual(chunks[1].messages.map(\.messageID), (7...14).map(String.init))
        XCTAssertTrue(chunks[0].text.contains("m1"))
    }

    func testWindowSkipsForbiddenAuthorOnly() {
        let items = [aiItem(1, text: "allowed one"), aiItem(2, text: "forbidden words", author: "bad"), aiItem(3, text: "allowed two")]
        let chunks = AIChunker.chunks(items, generation: 1) { $0.author?.externalID != "bad" }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertFalse(chunks[0].text.contains("forbidden"))
        XCTAssertTrue(chunks[0].text.contains("allowed one") && chunks[0].text.contains("allowed two"))
        XCTAssertEqual(chunks[0].authors.map(\.externalID), ["peer"])
    }

    func testOutgoingAuthorsAreNotRecorded() {
        let chunks = AIChunker.chunks([aiItem(1, text: "mine", author: "me", outgoing: true)], generation: 1) { _ in true }
        XCTAssertTrue(chunks[0].authors.isEmpty)
        XCTAssertTrue(chunks[0].text.contains("Вы: mine"))
    }

    func testLongLetterSplitWithHeaders() {
        let letter = AIIndexItem(
            sequence: 1, identity: MessageArchiveIdentity(service: "mail", accountID: "acc", conversationID: "INBOX", messageID: "l"),
            scope: .mailAccount(accountID: "acc"), author: ServiceIdentity(service: "mail", accountID: "acc", externalID: "p@example.invalid"),
            isOutgoing: false, date: Date(timeIntervalSince1970: 0), title: "Квартальный отчёт", text: String(repeating: "слово ", count: 700),
            removed: false)
        let chunks = AIChunker.chunks([letter], generation: 1) { _ in true }
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.text.hasPrefix("Тема: Квартальный отчёт") && $0.text.count <= AIChunker.maxCharacters + 200 })
        XCTAssertEqual(Set(chunks.map(\.id)).count, chunks.count)
    }

    func testChunkIDDeterministic() {
        let items = [aiItem(1, text: "a"), aiItem(2, text: "b")]
        let first = AIChunker.chunks(items, generation: 1) { _ in true }
        XCTAssertEqual(first.map(\.id), AIChunker.chunks(items, generation: 1) { _ in true }.map(\.id))
        XCTAssertNotEqual(first.map(\.id), AIChunker.chunks(items, generation: 2) { _ in true }.map(\.id))
        XCTAssertNotEqual(first.map(\.id), AIChunker.chunks([aiItem(1, text: "a"), aiItem(2, text: "edited")], generation: 1) { _ in true }.map(\.id))
    }

    func testRemovedItemsAreNeverChunked() {
        XCTAssertTrue(AIChunker.chunks([aiItem(1, text: "", removed: true)], generation: 1) { _ in true }.isEmpty)
    }
}
