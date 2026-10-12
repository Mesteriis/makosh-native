import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramUploadCaptionCurrentTests: XCTestCase {
    // Catches new captions retaining markup delimiters instead of native formatting.
    func testCurrentProjectionFormatsTheConfirmedInlineTokenSetAndFreezesOlderRules() throws {
        let raw = try TelegramFormattedText(text: " **bold** __italic__ ~~strike~~ ||hide|| `code` ")
        let current = try TelegramUploadCaptionRules.current.projection(raw)
        XCTAssertEqual(current.text, "bold italic strike hide code")
        XCTAssertEqual(current.entities, [.init(offset: 0, length: 4, kind: .bold),
            .init(offset: 5, length: 6, kind: .italic), .init(offset: 12, length: 6, kind: .strikethrough),
            .init(offset: 19, length: 4, kind: .spoiler), .init(offset: 24, length: 4, kind: .code)])
        XCTAssertEqual(try TelegramUploadCaptionRules.reference.projection(raw).text,
            "**bold** __italic__ ~~strike~~ ||hide|| `code`")
        XCTAssertEqual(try TelegramUploadCaptionRules.legacy.projection(raw), raw)
        XCTAssertEqual(raw.text, " **bold** __italic__ ~~strike~~ ||hide|| `code` ")
    }

    // Catches counting Unicode scalars/characters instead of preserving native UTF16 ranges.
    func testCurrentProjectionShiftsTypedEntitiesAfterEmojiAndLeavesAttributedMarkupLiteral() throws {
        let raw = try TelegramFormattedText(text: "😀 **bold😀** __keep__", entities: [
            .init(offset: 14, length: 8, kind: .underline)])
        let current = try TelegramUploadCaptionRules.current.projection(raw)
        XCTAssertEqual(current.text, "😀 bold😀 __keep__")
        XCTAssertEqual(current.entities, [.init(offset: 3, length: 6, kind: .bold),
            .init(offset: 10, length: 8, kind: .underline)])
        let overlapping = try TelegramFormattedText(text: "**keep**", entities: [
            .init(offset: 2, length: 4, kind: .italic)])
        XCTAssertEqual(try TelegramUploadCaptionRules.current.projection(overlapping), overlapping)
    }

    // Catches dropping code-block language, its initial newline, or non-BMP ranges.
    func testCurrentProjectionPreservesFencedLanguageAndWhitespaceRules() throws {
        for fence in ["```", "````"] {
            let raw = try TelegramFormattedText(text: "a \(fence)swift\nlet 😀 = 1\(fence) z")
            let current = try TelegramUploadCaptionRules.current.projection(raw)
            XCTAssertEqual(current.text, "a \nlet 😀 = 1 z")
            XCTAssertEqual(current.entities, [.init(offset: 2, length: 11, kind: .pre(language: "swift"))])
        }
        let raw = try TelegramFormattedText(text: "```\n  x  \n```")
        let current = try TelegramUploadCaptionRules.current.projection(raw)
        XCTAssertEqual(current.text, "x")
        XCTAssertEqual(current.entities, [.init(offset: 0, length: 1, kind: .pre(language: ""))])
    }

    // Catches formatting delimiters embedded in words or followed by non-boundary punctuation.
    func testUnmatchedAndNonBoundarySyntaxStaysLiteral() throws {
        let text = "word**literal** **open x**y __no\nline__ @(123) (Name)"
        let literal = try TelegramFormattedText(text: text)
        XCTAssertEqual(try TelegramUploadCaptionRules.current.projection(literal), literal)
        let punctuation = try TelegramUploadCaptionRules.current.projection(.init(text: "(**no**) **yes**, __yes__;"))
        XCTAssertEqual(punctuation.text, "(**no**) yes, yes;")
        XCTAssertEqual(punctuation.entities, [.init(offset: 9, length: 3, kind: .bold),
            .init(offset: 14, length: 3, kind: .italic)])
    }

    // Catches leaking URL fragments into hashtag entities or changing the cloud-only detection contract.
    func testCurrentProjectionDetectsCloudHashtagsWithUTF16AndURLPrecedence() throws {
        let raw = try TelegramFormattedText(text: "😀 #тег_2 https://example.com/#skip @name /start person@example.com #x ")
        let current = try TelegramUploadCaptionRules.current.projection(raw)
        XCTAssertEqual(current.text, "😀 #тег_2 https://example.com/#skip @name /start person@example.com #x")
        XCTAssertEqual(current.entities, [.init(offset: 3, length: 6, kind: .hashtag)])
        XCTAssertTrue(try TelegramUploadCaptionRules.current.projection(.init(text: "#x")).entities.isEmpty)
        let formatted = try TelegramFormattedText(text: "**#тег**", entities: [])
        XCTAssertEqual(try TelegramUploadCaptionRules.current.projection(formatted).entities, [
            .init(offset: 0, length: 4, kind: .bold), .init(offset: 0, length: 4, kind: .hashtag)])
    }

    // Catches using shortened markup output to bypass the reference's raw-input preflight.
    func testCurrentPreflightCountsRawMarkupAndNeverLaundersUnsupportedFormatting() throws {
        let raw = try TelegramFormattedText(text: " **x** ")
        XCTAssertFalse(TelegramUploadCaptionRules.current.canSend(raw, maximumUTF16Count: 1))
        XCTAssertTrue(TelegramUploadCaptionRules.current.canSend(raw, maximumUTF16Count: 5))
        for kind: TelegramTextEntityKind in [.unknown, .custom(type: 9), .phoneNumber,
            .customEmoji(stickerPack: nil, fileID: 100)] {
            let invalid = try TelegramFormattedText(text: " **x**", entities: [.init(offset: 0, length: 1, kind: kind)])
            XCTAssertThrowsError(try TelegramUploadCaptionRules.current.projection(invalid))
        }
    }
}
