import XCTest
import TelegramCore
@testable import MakoshTelegram

final class TelegramOutgoingFormattedTextTests: XCTestCase {
    func testAdmissionBoundsAndUnsupportedInlineSemantics() throws {
        XCTAssertFalse(telegramFormattedTextCanSend(try TelegramFormattedText(text: " \n\t")))
        XCTAssertTrue(telegramFormattedTextCanSend(try TelegramFormattedText(text: String(repeating: "😀", count: 2048))))
        XCTAssertFalse(telegramFormattedTextCanSend(try TelegramFormattedText(text: String(repeating: "😀", count: 2049))))
        for kind: TelegramTextEntityKind in [.unknown, .custom(type: 42), .phoneNumber,
                                             .customEmoji(stickerPack: nil, fileID: 123)] {
            let value = try TelegramFormattedText(text: "😀", entities: [.init(offset: 0, length: 2, kind: kind)])
            XCTAssertFalse(telegramFormattedTextCanSend(value))
            XCTAssertEqual(value.entities[0].kind, kind, "Rejected mutations retain lossless display DTO")
        }
    }
    func testNativeAttributesPreserveUnicodeNestedAndFormatOnlyDifference() throws {
        let value = try TelegramFormattedText(text: "e\u{301} 😀 bold", entities: [
            .init(offset: 0, length: 10, kind: .bold), .init(offset: 3, length: 2, kind: .italic)])
        XCTAssertTrue(telegramFormattedTextCanSend(value))
        let attribute = try XCTUnwrap(telegramOutgoingTextAttributes(value).first as? TextEntitiesMessageAttribute)
        XCTAssertEqual(try telegramFormattedText(text: value.text, entities: attribute.entities), value)
        XCTAssertNotEqual(value, try TelegramFormattedText(text: value.text))
        XCTAssertTrue(telegramOutgoingTextAttributes(try TelegramFormattedText(text: "plain")).isEmpty)
        XCTAssertThrowsError(try TelegramFormattedText(text: "😀", entities: [.init(offset: 1, length: 1, kind: .bold)]))
    }
}
