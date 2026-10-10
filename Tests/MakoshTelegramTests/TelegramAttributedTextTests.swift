import XCTest
import AppKit
@testable import MakoshTelegram

@MainActor final class TelegramAttributedTextTests: XCTestCase {
    func testDefaultTextUsesDynamicLabelColor() throws {
        let plain = try TelegramAttributedText.attributedString(TelegramFormattedText(text: "Synthetic"))
        let color = try XCTUnwrap(plain.attribute(.foregroundColor,at: 0,effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color,NSColor.labelColor)
        // Resolving the dynamic color under both appearances protects dark-mode readability.
        for appearanceName in [NSAppearance.Name.aqua,.darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertEqual(color.usingColorSpace(.deviceRGB),NSColor.labelColor.usingColorSpace(.deviceRGB))
            }
        }
    }
    func testNestedNativeStylesAndCustomEntitiesRoundTripExactly() throws {
        let value = try TelegramFormattedText(text: "A😀bcde",entities: [
            .init(offset: 0,length: 7,kind: .bold),.init(offset: 1,length: 2,kind: .italic),
            .init(offset: 3,length: 2,kind: .customEmoji(stickerPack: .id(id: 7,accessHash: 9),fileID: 11)),
            .init(offset: 5,length: 2,kind: .textMention(peerID: 42))])
        let native = try TelegramAttributedText.attributedString(value)
        let font = try XCTUnwrap(native.attribute(.font,at: 1,effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
        XCTAssertEqual(try TelegramAttributedText.formattedText(native),value)
    }
    func testUTF16InsertionMovesImmutableNonvisualEntityWithoutFlattening() throws {
        let value = try TelegramFormattedText(text: "😀abc",entities: [.init(offset: 3,length: 2,kind: .spoiler)])
        let native = NSMutableAttributedString(attributedString: try TelegramAttributedText.attributedString(value))
        native.insert(NSAttributedString(string: "X"),at: 0)
        let edited = try TelegramAttributedText.formattedText(native)
        XCTAssertEqual(edited.text,"X😀abc")
        XCTAssertEqual(edited.entities,[.init(offset: 4,length: 2,kind: .spoiler)])
    }
    func testNativeFormattingWithoutMarkersProducesEntities() throws {
        let native = NSMutableAttributedString(string: "abcd",attributes: [.font: NSFont.systemFont(ofSize: 14)])
        native.addAttribute(.font,value: NSFont.boldSystemFont(ofSize: 14),range: NSRange(location: 1,length: 2))
        native.addAttribute(.underlineStyle,value: NSUnderlineStyle.single.rawValue,range: NSRange(location: 1,length: 1))
        let value = try TelegramAttributedText.formattedText(native)
        XCTAssertTrue(value.entities.contains(.init(offset: 1,length: 2,kind: .bold)))
        XCTAssertTrue(value.entities.contains(.init(offset: 1,length: 1,kind: .underline)))
    }
    func testUnknownKindsPreservedAndMalformedOrRemovedVisualAttributesFailClosed() throws {
        let value = try TelegramFormattedText(text: "abcd",entities: [.init(offset: 0,length: 4,kind: .unknown)])
        XCTAssertEqual(try TelegramAttributedText.formattedText(TelegramAttributedText.attributedString(value)),value)
        let malformed = NSMutableAttributedString(string: "abc")
        malformed.addAttribute(NSAttributedString.Key("Makosh.TelegramEntity.0"),value: "forged",range: NSRange(location: 0,length: 1))
        XCTAssertThrowsError(try TelegramAttributedText.formattedText(malformed))
        let bold = try TelegramFormattedText(text: "abc",entities: [.init(offset: 0,length: 3,kind: .bold)])
        let removed = NSMutableAttributedString(attributedString: try TelegramAttributedText.attributedString(bold))
        removed.addAttribute(.font,value: NSFont.systemFont(ofSize: 14),range: NSRange(location: 0,length: 3))
        XCTAssertThrowsError(try TelegramAttributedText.formattedText(removed))
    }
    func testPreLanguageLinkQuoteAndExactUnicodeSurvive() throws {
        let value = try TelegramFormattedText(text: "e\u{301} abc",entities: [
            .init(offset: 0,length: 2,kind: .pre(language: "swift")),
            .init(offset: 3,length: 3,kind: .textURL(url: "https://example.invalid/a")),
            .init(offset: 3,length: 3,kind: .blockQuote(isCollapsed: true))])
        XCTAssertEqual(try TelegramAttributedText.formattedText(TelegramAttributedText.attributedString(value)),value)
    }
    func testLinkAttributeRemovalAndEmbeddedAttachmentsCannotSilentlyFlatten() throws {
        let linked = try TelegramFormattedText(text: "abc",entities: [.init(offset: 0,length: 3,kind: .textURL(url: "https://example.invalid"))])
        let native = NSMutableAttributedString(attributedString: try TelegramAttributedText.attributedString(linked))
        native.removeAttribute(.link,range: NSRange(location: 0,length: 3))
        XCTAssertThrowsError(try TelegramAttributedText.formattedText(native))
        let attachment = NSAttributedString(attachment: NSTextAttachment())
        XCTAssertThrowsError(try TelegramAttributedText.formattedText(attachment))
    }

}
