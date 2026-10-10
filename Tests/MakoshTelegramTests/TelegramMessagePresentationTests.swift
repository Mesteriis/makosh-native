import XCTest
import AppKit
@testable import MakoshTelegram

@MainActor final class TelegramMessagePresentationTests: XCTestCase {
    func testRevealKeyRejectsChangedVersionContextAndUnicodeBytes() throws {
        let original = try TelegramFormattedText(text: "é", entities: [.init(offset: 0, length: 1, kind: .spoiler)])
        let key = TelegramMessagePresentationKey(context: "account:chat:message", value: original)
        XCTAssertEqual(key, TelegramMessagePresentationKey(context: "account:chat:message", value: original))
        XCTAssertNotEqual(key, TelegramMessagePresentationKey(context: "other:chat:message", value: original))
        XCTAssertNotEqual(key, TelegramMessagePresentationKey(context: "account:chat:message",
            value: try TelegramFormattedText(text: "secret", entities: [.init(offset: 0, length: 6, kind: .spoiler)])))
        XCTAssertNotEqual(key, TelegramMessagePresentationKey(context: "account:chat:message",
            value: try TelegramFormattedText(text: "é", entities: [])))
        XCTAssertNotEqual(key, TelegramMessagePresentationKey(context: "account:chat:message",
            value: try TelegramFormattedText(text: "e\u{301}", entities: [.init(offset: 0, length: 2, kind: .spoiler)])))
    }
    func testNestedNativeStylesUseUTF16AndPreserveSourceWithoutEditorMarkers() throws {
        let value = try TelegramFormattedText(text: "😀 abc",entities: [
            .init(offset: 3,length: 3,kind: .bold),.init(offset: 3,length: 3,kind: .italic),
            .init(offset: 3,length: 3,kind: .underline),.init(offset: 3,length: 3,kind: .strikethrough)])
        let output = TelegramMessagePresentation.attributedString(value)
        XCTAssertEqual(output.string,value.text); XCTAssertEqual(output.length,6)
        let attrs = output.attributes(at: 3,effectiveRange: nil)
        let font = try XCTUnwrap(attrs[.font] as? NSFont)
        let traits = NSFontManager.shared.traits(of: font)
        XCTAssertTrue(traits.contains(.boldFontMask)); XCTAssertTrue(traits.contains(.italicFontMask))
        XCTAssertNotNil(attrs[.underlineStyle]); XCTAssertNotNil(attrs[.strikethroughStyle])
        output.enumerateAttributes(in: NSRange(location: 0,length: output.length)) { attrs,_,_ in
            XCTAssertFalse(attrs.keys.contains { $0.rawValue.hasPrefix("Makosh.TelegramEntity.") })
        }
        XCTAssertEqual(value.entities.count,4)
    }
    func testSpoilersMaskSurrogatesAndNestedRangesAndRemoveCompleteLinkTarget() throws {
        let text = "https://example.invalid/SECRET😀"
        let length = text.utf16.count
        let start = (text as NSString).range(of: "SECRET").location
        let value = try TelegramFormattedText(text: text,entities: [
            .init(offset: 0,length: length,kind: .url),
            .init(offset: start,length: length-start,kind: .spoiler),
            .init(offset: start+1,length: 3,kind: .spoiler),
            .init(offset: start,length: length-start,kind: .bold)])
        let hidden = TelegramMessagePresentation.attributedString(value)
        XCTAssertEqual(hidden.length,length); XCTAssertFalse(hidden.string.contains("SECRET")); XCTAssertFalse(hidden.string.contains("😀"))
        XCTAssertEqual((hidden.string as NSString).substring(from: start),String(repeating: "█",count: length-start))
        hidden.enumerateAttributes(in: NSRange(location: 0,length: length)) { attrs,_,_ in
            XCTAssertNil(attrs[.link]); XCTAssertFalse(String(describing: attrs).contains("SECRET"))
        }
        let revealed = TelegramMessagePresentation.attributedString(value,revealingSpoilers: true)
        XCTAssertEqual(revealed.string,text); XCTAssertNotNil(revealed.attribute(.link,at: 0,effectiveRange: nil))
        XCTAssertEqual(value.text,text)
    }
    func testAdjacentSpoilersAreMergedAndUnknownEmojiRemainPlainFallback() throws {
        let value = try TelegramFormattedText(text: "abcdef😀",entities: [
            .init(offset: 0,length: 3,kind: .spoiler),.init(offset: 3,length: 3,kind: .spoiler),
            .init(offset: 6,length: 2,kind: .customEmoji(stickerPack: .id(id: 7,accessHash: 8),fileID: 9)),
            .init(offset: 6,length: 2,kind: .unknown)])
        let output = TelegramMessagePresentation.attributedString(value)
        XCTAssertEqual(output.string,"██████😀")
        XCTAssertNil(output.attribute(.attachment,at: 6,effectiveRange: nil))
        XCTAssertEqual(Set(output.attributes(at: 6,effectiveRange: nil).keys),[.font,.foregroundColor])
    }
    func testSafeLinksOnlyAndExactUnicodeSubstring() throws {
        for text in ["https://example.invalid/a", "http://example.invalid:8080/a", "mailto:test@example.invalid", "example.invalid/a"] {
            let value = try TelegramFormattedText(text: "open",entities: [.init(offset: 0,length: 4,kind: .textURL(url: text))])
            XCTAssertNotNil(TelegramMessagePresentation.attributedString(value).attribute(.link,at: 0,effectiveRange: nil))
        }
        for text in ["javascript:alert(1)","file:///tmp/x","tg://resolve?domain=x","https://user:pass@example.invalid",
                     "https://example.invalid/%0Ahidden","https://example.invalid/\u{202e}x","https://example.invalid/a b",
                     "https:///path","mailto:test@example.invalid?body=secret","https://example.invalid:0", "/relative", "//example.invalid/path"] {
            let value = try TelegramFormattedText(text: "open",entities: [.init(offset: 0,length: 4,kind: .textURL(url: text))])
            XCTAssertNil(TelegramMessagePresentation.attributedString(value).attribute(.link,at: 0,effectiveRange: nil),text)
        }
        let text = "😀 https://example.invalid/é"
        let range = (text as NSString).range(of: "https://example.invalid/é")
        let value = try TelegramFormattedText(text: text,entities: [.init(offset: range.location,length: range.length,kind: .url)])
        let url = try XCTUnwrap(TelegramMessagePresentation.attributedString(value).attribute(.link,at: range.location,effectiveRange: nil) as? URL)
        XCTAssertEqual(url.path,"/é")
    }
    func testCodeQuoteAndDynamicColors() throws {
        let value = try TelegramFormattedText(text: "code\nquote",entities: [
            .init(offset: 0,length: 4,kind: .pre(language: "swift")),.init(offset: 5,length: 5,kind: .blockQuote(isCollapsed: false))])
        let output = TelegramMessagePresentation.attributedString(value)
        XCTAssertTrue(try XCTUnwrap(output.attribute(.font,at: 0,effectiveRange: nil) as? NSFont).isFixedPitch)
        XCTAssertEqual((output.attribute(.paragraphStyle,at: 5,effectiveRange: nil) as? NSParagraphStyle)?.headIndent,12)
        XCTAssertEqual(output.attribute(.foregroundColor,at: 0,effectiveRange: nil) as? NSColor,NSColor.labelColor)
        XCTAssertEqual(output.attribute(.foregroundColor,at: 5,effectiveRange: nil) as? NSColor,NSColor.secondaryLabelColor)
    }
}
