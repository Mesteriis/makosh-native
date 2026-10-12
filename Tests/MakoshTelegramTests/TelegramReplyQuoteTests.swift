import XCTest
@testable import MakoshTelegram

final class TelegramReplyQuoteTests: XCTestCase {
    func testQuoteCanSelectFromIncomingMessageWithMoreThanComposerEntityLimit() throws {
        let source = try TelegramFormattedText(text: String(repeating: "x", count: 1025), entities:
            (0..<1025).map { .init(offset: $0, length: 1, kind: .bold) })
        let quote = TelegramReplyQuote(source: source, selection: .init(location: 1024, length: 1))
        XCTAssertEqual(quote?.formattedText.entities, [.init(offset: 0, length: 1, kind: .bold)])
    }
    func testLegacyComposerRejectsNestedQuoteAndNewSchemaRetainsIt() throws {
        let source = try TelegramFormattedText(text: "quoted")
        let quote = try XCTUnwrap(TelegramReplyQuote(source: source, selection: .init(location: 0, length: 6)))
        let original = TelegramComposerDraft(accountID: 1, chatID: 42, text: "answer", replyTarget: .init(peerID: 42, namespace: 0, messageID: 7))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var target = try XCTUnwrap(fields["replyTarget"] as? [String: Any])
        target["quote"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quote)); fields["replyTarget"] = target
        let legacy = try JSONDecoder().decode(TelegramComposerDraft.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertFalse(legacy.isValid, "An older schema must never silently discard a selected quote")
        fields["schemaVersion"] = 5
        let current = try JSONDecoder().decode(TelegramComposerDraft.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertTrue(current.isValid)
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        XCTAssertNotNil((roundTrip["replyTarget"] as? [String: Any])?["quote"])
    }
    func testSelectionClipsQuoteableEntitiesUsingUTF16AndTrimsReferenceWhitespace() throws {
        let source = try TelegramFormattedText(text: "prefix 😀 bold end", entities: [
            .init(offset: 7, length: 7, kind: .bold), .init(offset: 10, length: 4, kind: .italic),
            .init(offset: 10, length: 4, kind: .textURL(url: "https://example.invalid"))])
        let quote = try XCTUnwrap(TelegramReplyQuote(source: source, selection: .init(location: 6, length: 9)))
        XCTAssertEqual(quote.formattedText.text, "😀 bold")
        XCTAssertEqual(quote.selection, .init(location: 7, length: 7))
        XCTAssertEqual(quote.formattedText.entities, [.init(offset: 0, length: 7, kind: .bold), .init(offset: 3, length: 4, kind: .italic)])
        XCTAssertTrue(quote.matches(source: source))
    }
    func testPreTrimLengthLimitAndScalarBoundariesCannotBeBypassed() throws {
        let source = try TelegramFormattedText(text: "   😀  ")
        XCTAssertNil(TelegramReplyQuote(source: source, selection: .init(location: 0, length: 7), maximumLength: 2))
        XCTAssertNil(TelegramReplyQuote(source: source, selection: .init(location: 3, length: 1)))
        XCTAssertNil(TelegramReplyQuote(source: source, selection: .init(location: -1, length: 2)))
        XCTAssertNil(TelegramReplyQuote(source: source, selection: .init(location: 0, length: Int.max)))
        XCTAssertNil(TelegramReplyQuote(source: source, selection: .init(location: 0, length: 0)))
        XCTAssertNotNil(TelegramReplyQuote(source: source, selection: .init(location: 3, length: 2), maximumLength: 2))
    }
    func testReferenceLineSeparatorsAndAttachmentsBecomeNewlinesBeforeTrim() throws {
        let source = try TelegramFormattedText(text: "\u{2028}a\u{fffc}b\u{2028}")
        let quote = try XCTUnwrap(TelegramReplyQuote(source: source, selection: .init(location: 0, length: 5)))
        XCTAssertEqual(quote.formattedText.text, "a\nb")
        XCTAssertEqual(quote.selection, .init(location: 1, length: 3))
        XCTAssertTrue(quote.matches(source: source))
        XCTAssertNil(TelegramReplyQuote(source: try .init(text: " \n\t"), selection: .init(location: 0, length: 3)))
    }
    func testOnlyQuoteableEntitiesRetainCustomEmojiProvenanceAndRejectPartialCustomSelection() throws {
        let source = try TelegramFormattedText(text: "👨‍👩‍👧 code", entities: [
            .init(offset: 0, length: 8, kind: .customEmoji(stickerPack: .name("Synthetic"), fileID: 100)),
            .init(offset: 9, length: 4, kind: .code), .init(offset: 9, length: 4, kind: .spoiler)])
        let quote = try XCTUnwrap(TelegramReplyQuote(source: source, selection: .init(location: 0, length: 13)))
        XCTAssertEqual(quote.formattedText.entities, [source.entities[0], source.entities[2]])
        XCTAssertNil(TelegramReplyQuote(source: source, selection: .init(location: 0, length: 2)))
    }
    func testStoredQuoteCannotAuthorizeChangedTextOrFormattingAndRoundTripsExactly() throws {
        let source = try TelegramFormattedText(text: "e\u{301}", entities: [.init(offset: 0, length: 2, kind: .bold)])
        let quote = try XCTUnwrap(TelegramReplyQuote(source: source, selection: .init(location: 0, length: 2)))
        XCTAssertFalse(quote.matches(source: try .init(text: "é")))
        XCTAssertFalse(quote.matches(source: try .init(text: source.text)))
        let decoded = try JSONDecoder().decode(TelegramReplyQuote.self, from: JSONEncoder().encode(quote))
        XCTAssertEqual(decoded, quote); XCTAssertTrue(decoded.matches(source: source))
    }
}
