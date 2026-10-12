import XCTest
import AppKit
@testable import MakoshTelegram

@MainActor final class TelegramCodeHighlightTests: XCTestCase {
    func testLengthDelimitedSpansKeepNULAndMapNonBMPCombiningAndCRLFExactly() throws {
        let source = "😀\0let e\u{301} = 2\r\n"
        let highlight = try XCTUnwrap(TelegramCodeHighlight(source: source, byteSpans: [
            .init(offset: 5, length: 3, role: 6), .init(offset: 10, length: 2, role: 5),
            .init(offset: 15, length: 1, role: 3)]))
        XCTAssertEqual(highlight.spans.map(\.range), [NSRange(location: 3, length: 3),
            NSRange(location: 8, length: 1), NSRange(location: 12, length: 1)])
        XCTAssertEqual(highlight.spans.map(\.role), [.blue, .purple, .green])
        XCTAssertTrue(highlight.matches(source))
        let output = TelegramCodeHighlightPresentation.attributedString(try code(source), highlight: highlight)
        XCTAssertEqual(Array(output.string.utf8), [240,159,152,128,0,108,101,116,32,101,204,129,32,61,32,50,13,10])
        XCTAssertEqual(output.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor, .linkColor)
    }

    func testNativeRangesMustBeOrderedDisjointPositiveAndScalarAligned() {
        let malformed: [[TelegramCodeHighlightByteSpan]] = [
            [.init(offset: -1, length: 1, role: 6)], [.init(offset: 0, length: -1, role: 6)],
            [.init(offset: 0, length: 0, role: 6)], [.init(offset: 0, length: .max, role: 6)],
            [.init(offset: .max, length: 1, role: 6)], [.init(offset: 1, length: 3, role: 6)],
            [.init(offset: 0, length: 3, role: 6)], [.init(offset: 6, length: 1, role: 6)],
            [.init(offset: 0, length: 4, role: 99)],
            [.init(offset: 4, length: 1, role: 6), .init(offset: 0, length: 4, role: 3)],
            [.init(offset: 0, length: 5, role: 6), .init(offset: 4, length: 1, role: 3)]]
        for spans in malformed { XCTAssertNil(TelegramCodeHighlight(source: "😀x", byteSpans: spans)) }
        XCTAssertNotNil(TelegramCodeHighlight(source: "😀x", byteSpans: [
            .init(offset: 0, length: 4, role: 3), .init(offset: 4, length: 1, role: 6)]))
    }

    func testOversizedSourceAndTokenFloodFailClosed() {
        XCTAssertNil(TelegramCodeHighlight(source: String(repeating: "x", count: 32769), byteSpans: []))
        let flood = (0..<8193).map { TelegramCodeHighlightByteSpan(offset: $0, length: 1, role: 6) }
        XCTAssertNil(TelegramCodeHighlight(source: String(repeating: "x", count: 9000), byteSpans: flood))
        XCTAssertNotNil(TelegramCodeHighlight(source: String(repeating: "x", count: 32768), byteSpans: [
            .init(offset: 32767, length: 1, role: 6)]))
    }

    func testCanonicalEquivalentButDifferentSourceCannotReuseColors() throws {
        let original = try XCTUnwrap(TelegramCodeHighlight(source: "éx", byteSpans: [.init(offset: 2, length: 1, role: 6)]))
        XCTAssertFalse(original.matches("e\u{301}x"))
        let value = try code("e\u{301}x")
        let output = TelegramCodeHighlightPresentation.attributedString(value, highlight: original)
        XCTAssertEqual(Array(output.string.utf8), [101,204,129,120])
        XCTAssertEqual(output.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor, .labelColor)
    }

    func testColorPresentationPreservesAllExistingAttributesIncludingSafeLinks() throws {
        let value = try code("let x", extra: [.init(offset: 0, length: 3, kind: .bold),
            .init(offset: 0, length: 3, kind: .italic), .init(offset: 0, length: 3, kind: .underline),
            .init(offset: 0, length: 3, kind: .strikethrough),
            .init(offset: 4, length: 1, kind: .textURL(url: "https://example.invalid"))])
        let highlight = try XCTUnwrap(TelegramCodeHighlight(source: value.text,
            byteSpans: [.init(offset: 0, length: 5, role: 4)]))
        let baseline = TelegramMessagePresentation.attributedString(value)
        let output = TelegramCodeHighlightPresentation.attributedString(value, highlight: highlight)
        XCTAssertEqual(Array(output.string.utf8), Array(value.text.utf8))
        for index in 0..<output.length {
            var before = baseline.attributes(at: index, effectiveRange: nil)
            var after = output.attributes(at: index, effectiveRange: nil)
            before.removeValue(forKey: .foregroundColor); after.removeValue(forKey: .foregroundColor)
            XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: after))
        }
        XCTAssertEqual(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
        XCTAssertEqual(output.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, .linkColor)
        XCTAssertEqual(output.attribute(.link, at: 4, effectiveRange: nil) as? URL, URL(string: "https://example.invalid"))
    }

    func testHiddenSpoilerKeepsMaskAndUniformColorUntilExplicitReveal() throws {
        let value = try code("let SECRET😀", extra: [.init(offset: 4, length: 8, kind: .spoiler)])
        let highlight = try XCTUnwrap(TelegramCodeHighlight(source: value.text,
            byteSpans: [.init(offset: 0, length: 14, role: 4)]))
        let output = TelegramCodeHighlightPresentation.attributedString(value, highlight: highlight)
        XCTAssertEqual(output.string, "let ████████")
        XCTAssertEqual(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
        for index in 4..<12 {
            XCTAssertEqual(output.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
            XCTAssertNil(output.attribute(.link, at: index, effectiveRange: nil))
        }
        let revealed = TelegramCodeHighlightPresentation.attributedString(value, highlight: highlight, revealingSpoilers: true)
        XCTAssertEqual(Array(revealed.string.utf8), Array(value.text.utf8))
        XCTAssertEqual(revealed.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, .systemRed)
    }

    func testSpoilerIntersectingLinkCannotRestoreItsTarget() throws {
        let value = try code("open SECRET", extra: [
            .init(offset: 0, length: 11, kind: .textURL(url: "https://example.invalid/SECRET")),
            .init(offset: 5, length: 6, kind: .spoiler)])
        let highlight = try XCTUnwrap(TelegramCodeHighlight(source: value.text,
            byteSpans: [.init(offset: 0, length: 11, role: 6)]))
        let output = TelegramCodeHighlightPresentation.attributedString(value, highlight: highlight)
        XCTAssertEqual(output.string, "open ██████")
        for index in 0..<output.length { XCTAssertNil(output.attribute(.link, at: index, effectiveRange: nil)) }
        XCTAssertFalse(String(describing: output).contains("SECRET"))
    }

    func testSameParsedResultRendersCurrentPaletteWithoutChangingSource() throws {
        let value = try code("a b c d e f g")
        let highlight = try XCTUnwrap(TelegramCodeHighlight(source: value.text,
            byteSpans: (0..<7).map { .init(offset: $0 * 2, length: 1, role: UInt32($0)) }))
        let first = TelegramCodeHighlightPalette(text: .black, comment: .gray, property: .purple,
            green: .green, red: .red, purple: .magenta, blue: .blue)
        let second = TelegramCodeHighlightPalette(text: .white, comment: .brown, property: .orange,
            green: .cyan, red: .yellow, purple: .red, blue: .green)
        let output = TelegramCodeHighlightPresentation.attributedString(value, highlight: highlight, palette: first)
        let changed = TelegramCodeHighlightPresentation.attributedString(value, highlight: highlight, palette: second)
        let expected: [NSColor] = [.black, .gray, .purple, .green, .red, .magenta, .blue]
        let next: [NSColor] = [.white, .brown, .orange, .cyan, .yellow, .red, .green]
        for index in 0..<7 {
            XCTAssertEqual(output.attribute(.foregroundColor, at: index * 2, effectiveRange: nil) as? NSColor, expected[index])
            XCTAssertEqual(changed.attribute(.foregroundColor, at: index * 2, effectiveRange: nil) as? NSColor, next[index])
        }
        XCTAssertEqual(changed.string, value.text)
    }

    func testMissingResultKeepsNativeFallbackPresentation() throws {
        let value = try code("let x")
        let baseline = TelegramMessagePresentation.attributedString(value)
        XCTAssertEqual(TelegramCodeHighlightPresentation.attributedString(value, highlight: nil), baseline)
    }

    private func code(_ source: String, extra: [TelegramTextEntity] = []) throws -> TelegramFormattedText {
        try TelegramFormattedText(text: source, entities: [.init(offset: 0, length: source.utf16.count,
            kind: .pre(language: "swift"))] + extra)
    }
}
