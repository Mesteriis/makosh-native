import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramFormattedTextTests: XCTestCase {
    func testScalarBoundariesAndCrossingRangesRejectButNestedStylesRemain() throws {
        XCTAssertThrowsError(try TelegramFormattedText(text: "😀abc",entities: [.init(offset: 1,length: 1,kind: .bold)]))
        XCTAssertThrowsError(try TelegramFormattedText(text: "abcd",entities: [.init(offset: 0,length: 3,kind: .bold),.init(offset: 2,length: 2,kind: .italic)]))
        XCTAssertThrowsError(try TelegramFormattedText(text: "abc",entities: [.init(offset: 0,length: 0,kind: .bold)]))
        XCTAssertThrowsError(try TelegramFormattedText(text: "abc",entities: [.init(offset: Int.max,length: Int.max,kind: .bold)]))
        XCTAssertNoThrow(try TelegramFormattedText(text: "😀abc",entities: [.init(offset: 0,length: 5,kind: .bold),.init(offset: 2,length: 3,kind: .italic)]))
    }
    func testAllNativeEntityKindsRoundTripIncludingUnsupportedKinds() throws {
        let kinds: [TelegramTextEntityKind] = [.unknown,.mention,.hashtag,.botCommand,.url,.email,.bold,.italic,.code,
            .pre(language: "swift"),.textURL(url: "https://example.invalid"),.textMention(peerID: 42),.phoneNumber,
            .strikethrough,.blockQuote(isCollapsed: true),.underline,.bankCard,.spoiler,
            .customEmoji(stickerPack: .id(id: 2,accessHash: 3),fileID: 4),.custom(type: 99)]
        for kind in kinds {
            let original = try TelegramFormattedText(text: "abcd",entities: [.init(offset: 0,length: 4,kind: kind)])
            XCTAssertEqual(try telegramFormattedText(text: original.text,entities: original.engineEntities()),original)
        }
        for kind in [TelegramTextEntityKind.unknown,.custom(type: 2),.phoneNumber] {
            XCTAssertFalse(try TelegramFormattedText(text: "abc",entities: [.init(offset: 0,length: 3,kind: kind)]).isEditable)
        }
    }
    func testExactUTF8AndTypedEntityPayloadEquality() throws {
        XCTAssertNotEqual(try TelegramFormattedText(text: "é"),try TelegramFormattedText(text: "e\u{301}"))
        let a = try TelegramFormattedText(text: "abc",entities: [.init(offset: 0,length: 3,kind: .pre(language: "é"))])
        let b = try TelegramFormattedText(text: "abc",entities: [.init(offset: 0,length: 3,kind: .pre(language: "e\u{301}"))])
        XCTAssertNotEqual(a,b)
        XCTAssertNotEqual(try TelegramFormattedText(text: "abc"),a)
    }
}
