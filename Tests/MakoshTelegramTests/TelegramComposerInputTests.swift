import XCTest
@testable import MakoshTelegram

final class TelegramComposerInputTests: XCTestCase {
    func testUTF16SelectionAndValidatedCodableRoundTrip() throws {
        let rich = try TelegramFormattedText(text: "😀 e\u{301}", entities: [.init(offset: 3, length: 2, kind: .bold)])
        let input = try TelegramComposerInput(formattedText: rich, selection: .init(location: 2, length: 3))
        XCTAssertEqual(try JSONDecoder().decode(TelegramComposerInput.self, from: JSONEncoder().encode(input)), input)
        XCTAssertEqual(try TelegramComposerInput(formattedText: rich).selection.location, 5)
        for selection in [TelegramInputSelection(location: 1, length: 0), .init(location: -1, length: 0), .init(location: 0, length: Int.max), .init(location: 5, length: 1)] {
            XCTAssertThrowsError(try TelegramComposerInput(formattedText: rich, selection: selection))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        object["selection"] = ["location": 1, "length": 0]
        XCTAssertThrowsError(try JSONDecoder().decode(TelegramComposerInput.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testFormatSelectionAndReplyMutationsPreserveRichInputAndProtectACK() throws {
        var store = TelegramDraftStore()
        let plain = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "same"))
        let first = try XCTUnwrap(store.save(input: plain, accountID: 1, chatID: 2))
        let rich = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "same", entities: [.init(offset: 0, length: 4, kind: .bold)]))
        let formatted = try XCTUnwrap(store.save(input: rich, accountID: 1, chatID: 2))
        XCTAssertNotEqual(first.revision, formatted.revision)
        XCTAssertNil(store.acknowledge(sentText: "same", revision: formatted.revision, accountID: 1, chatID: 2))
        let selected = try TelegramComposerInput(formattedText: rich.formattedText, selection: .init(location: 0, length: 4))
        let moved = try XCTUnwrap(store.save(input: selected, accountID: 1, chatID: 2))
        XCTAssertNil(store.acknowledge(sentInput: rich, revision: formatted.revision, accountID: 1, chatID: 2))
        let reply = try XCTUnwrap(store.setReplyTarget(.init(peerID: 2, namespace: 0, messageID: 1), accountID: 1, chatID: 2))
        XCTAssertEqual(reply.input, selected); XCTAssertNotEqual(reply.revision, moved.revision)
        let cleared = try XCTUnwrap(store.acknowledge(sentInput: selected, revision: reply.revision, accountID: 1, chatID: 2))
        XCTAssertEqual(cleared.input, .empty); XCTAssertNil(cleared.replyTarget)
    }
    func testExactUnicodeAndUnsupportedEntityRetention() throws {
        let a = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "é"))
        let b = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "e\u{301}"))
        XCTAssertNotEqual(a, b)
        let unsupported = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "x", entities: [.init(offset: 0, length: 1, kind: .unknown)]))
        XCTAssertFalse(unsupported.formattedText.isEditable)
        XCTAssertEqual(try JSONDecoder().decode(TelegramComposerInput.self, from: JSONEncoder().encode(unsupported)), unsupported)
    }
    func testEntityCountBoundaryAndDecoderRejectsExcessBeforeFormattedValidation() throws {
        let entity = TelegramTextEntity(offset: 0, length: 1, kind: .bold)
        let accepted = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "x", entities: Array(repeating: entity, count: 1024)))
        XCTAssertEqual(accepted.formattedText.entities.count, 1024)
        let bytes = try JSONEncoder().encode(accepted)
        XCTAssertEqual(try JSONDecoder().decode(TelegramComposerInput.self, from: bytes), accepted)
        XCTAssertThrowsError(try TelegramComposerInput(formattedText: TelegramFormattedText(text: "x", entities: Array(repeating: entity, count: 1025))))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var content = try XCTUnwrap(object["formattedText"] as? [String: Any])
        var entities = try XCTUnwrap(content["entities"] as? [[String: Any]])
        entities.append(try XCTUnwrap(entities.first))
        content["entities"] = entities; object["formattedText"] = content
        XCTAssertThrowsError(try JSONDecoder().decode(TelegramComposerInput.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
