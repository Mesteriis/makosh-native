import XCTest
@testable import MakoshTelegram

final class TelegramMessageBlocksTests: XCTestCase {
    func testEmojiNewlinesStylesAndLanguageAreLossless() throws {
        let text = "😀\ne\u{301}\nquote\nend"
        let source = try TelegramFormattedText(text: text, entities: [
            .init(offset: 3, length: 2, kind: .pre(language: "swift")),
            .init(offset: 6, length: 5, kind: .blockQuote(isCollapsed: true)),
            .init(offset: 0, length: text.utf16.count, kind: .bold),
            .init(offset: 6, length: 5, kind: .italic)])
        let blocks = telegramMessageBlocks(source)
        XCTAssertEqual(blocks.map(\.kind), [.text, .code(language: "swift"), .text, .quote(isCollapsed: true), .text])
        XCTAssertTrue(blocks.map { $0.value.text }.joined().utf8.elementsEqual(text.utf8))
        XCTAssertEqual(blocks.map(\.range), [0..<3, 3..<5, 5..<6, 6..<11, 11..<15])
        XCTAssertTrue(blocks[1].value.entities.contains(.init(offset: 0, length: 2, kind: .pre(language: "swift"))))
        XCTAssertEqual(blocks[3].value.entities, [.init(offset: 0, length: 5, kind: .bold), .init(offset: 0, length: 5, kind: .italic)])
        XCTAssertEqual(source.entities.count, 4)
    }

    func testEqualAndNestedStructuresFallBackWithoutDroppingEntities() throws {
        for entities: [TelegramTextEntity] in [
            [.init(offset: 0, length: 6, kind: .pre(language: nil)), .init(offset: 0, length: 6, kind: .blockQuote(isCollapsed: false))],
            [.init(offset: 0, length: 6, kind: .blockQuote(isCollapsed: true)), .init(offset: 1, length: 3, kind: .pre(language: "x"))],
            [.init(offset: 0, length: 6, kind: .pre(language: "a")), .init(offset: 0, length: 6, kind: .pre(language: "b"))]
        ] {
            let source = try TelegramFormattedText(text: "abcdef", entities: entities)
            let blocks = telegramMessageBlocks(source)
            XCTAssertEqual(blocks.count, 1); XCTAssertEqual(blocks[0].kind, .text)
            XCTAssertEqual(blocks[0].value, source)
        }
    }

    @MainActor func testSpoilersAcrossBlocksRemainHiddenAndSpanningLinksFallBack() throws {
        let source = try TelegramFormattedText(text: "abcdef", entities: [
            .init(offset: 2, length: 2, kind: .pre(language: nil)),
            .init(offset: 0, length: 6, kind: .spoiler)])
        let blocks = telegramMessageBlocks(source)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.map { TelegramMessagePresentation.plainText($0.value) }.joined(), "██████")
        let linked = try TelegramFormattedText(text: source.text, entities: source.entities + [
            .init(offset: 0, length: 6, kind: .textURL(url: "https://example.invalid/secret"))])
        let preserved = telegramMessageBlocks(linked)
        XCTAssertEqual(preserved.count, 1); XCTAssertEqual(preserved[0].value, linked)
        let shown = TelegramMessagePresentation.attributedString(preserved[0].value)
        XCTAssertNil(shown.attribute(.link, at: 0, effectiveRange: nil))
        // The visible code slice must not recover the target of a link whose
        // hidden substring lies in a different block.
        let outside = try TelegramFormattedText(text: "abcdef", entities: [
            .init(offset: 2, length: 2, kind: .pre(language: nil)),
            .init(offset: 0, length: 2, kind: .spoiler),
            .init(offset: 0, length: 6, kind: .textURL(url: "https://example.invalid/ab"))])
        let outsideBlocks = telegramMessageBlocks(outside)
        XCTAssertEqual(outsideBlocks.count, 1)
        let outsideShown = TelegramMessagePresentation.attributedString(outsideBlocks[0].value)
        XCTAssertEqual(outsideShown.string, "██cdef")
        XCTAssertNil(outsideShown.attribute(.link, at: 3, effectiveRange: nil))
    }

    func testEmptyAndPlainAndAdjacentStructuralBlocksPreserveEveryByte() throws {
        for text in ["", "😀\n", "e\u{301}"] {
            let source = try TelegramFormattedText(text: text)
            XCTAssertEqual(telegramMessageBlocks(source).map(\.value), [source])
        }
        let source = try TelegramFormattedText(text: "ab\ncd", entities: [
            .init(offset: 0, length: 3, kind: .blockQuote(isCollapsed: false)),
            .init(offset: 3, length: 2, kind: .pre(language: nil))])
        let blocks = telegramMessageBlocks(source)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks.map { $0.value.text }.joined().utf8.elementsEqual(source.text.utf8))
    }
}
