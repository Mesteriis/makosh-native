import XCTest
import AppKit
@testable import MakoshTelegram

@MainActor final class TelegramMessagePresentationTests: XCTestCase {
    func testSelectionLabelMasksSpoilerSurrogatesWithoutChangingSource() throws {
        let text = "Visible SECRET😀"
        let range = (text as NSString).range(of: "SECRET😀")
        let value = try TelegramFormattedText(text: text, entities: [
            .init(offset: range.location, length: range.length, kind: .spoiler),
            .init(offset: range.location, length: range.length, kind: .bold)])
        let message = TelegramMessage(id: "selection", date: Date(timeIntervalSince1970: 0), text: text,
            author: "Synthetic author", isOutgoing: false, delivery: .none,
            actionMetadata: .init(peerID: 7, namespace: 0, messageID: 1, fingerprint: "version", text: text,
                authorID: 8, canReply: true, canEdit: false, canForward: true,
                canDeleteLocally: true, canDeleteForEveryone: false, formattedText: value))
        let label = TelegramMessagePresentation.selectionLabel(for: message)
        XCTAssertEqual(label, "Synthetic author: Visible " + String(repeating: "█", count: range.length))
        XCTAssertFalse(label.contains("SECRET")); XCTAssertFalse(label.contains("😀"))
        XCTAssertEqual(message.formattedTextForDisplay, value); XCTAssertEqual(message.text, text)
    }
    func testSelectionLabelDoesNotFallBackToRawTextWhenFormattingIsUnavailable() throws {
        var message = TelegramMessage(id: "selection", date: Date(timeIntervalSince1970: 0), text: "SECRET",
            author: "Synthetic author", isOutgoing: false, delivery: .none)
        for value in [nil, try TelegramFormattedText(text: "different")] as [TelegramFormattedText?] {
            message.actionMetadata = .init(peerID: 7, namespace: 0, messageID: 1, fingerprint: "version", text: message.text,
                authorID: 8, canReply: true, canEdit: false, canForward: true,
                canDeleteLocally: true, canDeleteForEveryone: false, formattedText: value)
            XCTAssertNil(message.formattedTextForDisplay)
            XCTAssertEqual(TelegramMessagePresentation.selectionLabel(for: message),
                "Synthetic author: Форматирование сообщения недоступно")
        }
        let attachment = TelegramMessage(id: "attachment", date: message.date, text: "",
            author: message.author, isOutgoing: false, delivery: .none)
        XCTAssertEqual(TelegramMessagePresentation.selectionLabel(for: attachment), "Synthetic author: Сообщение с вложением")
    }

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
    func testQuoteFoldingUsesThreeVisualLinesAndAvailableWidth() throws {
        let short = try TelegramFormattedText(text: "one\ntwo\nthree")
        let long = try TelegramFormattedText(text: "one\ntwo\nthree\nfour")
        XCTAssertFalse(TelegramMessagePresentation.quoteNeedsExpansion(short, width: 300))
        XCTAssertTrue(TelegramMessagePresentation.quoteNeedsExpansion(long, width: 300))
        let wrapped = try TelegramFormattedText(text: String(repeating: "word ", count: 30))
        XCTAssertFalse(TelegramMessagePresentation.quoteNeedsExpansion(wrapped, width: 2000))
        XCTAssertTrue(TelegramMessagePresentation.quoteNeedsExpansion(wrapped, width: 100))
        for width: CGFloat in [0, -1, .infinity, .nan] {
            XCTAssertFalse(TelegramMessagePresentation.quoteNeedsExpansion(long, width: width))
        }
    }
    func testCodeLanguageIsBoundedAndCannotExposeHiddenMetadata() throws {
        let plain = try TelegramFormattedText(text: "  code😀\n")
        let hidden = try TelegramFormattedText(text: plain.text, entities: [.init(offset: 2, length: 4, kind: .spoiler)])
        XCTAssertEqual(TelegramMessagePresentation.codeLanguage("c++", in: plain), "c++")
        XCTAssertEqual(TelegramMessagePresentation.codeLanguage(String(repeating: "a", count: 30), in: plain), String(repeating: "a", count: 15) + "…")
        for language in ["", "swift\nsecret", "x\u{202e}secret", " swift", "s\u{0}x"] {
            XCTAssertNil(TelegramMessagePresentation.codeLanguage(language, in: plain))
        }
        XCTAssertNil(TelegramMessagePresentation.codeLanguage("swift", in: hidden))
        XCTAssertEqual(TelegramMessagePresentation.codeLanguage("swift", in: hidden, revealingSpoilers: true), "swift")
        XCTAssertEqual(TelegramMessagePresentation.plainText(hidden), "  ████😀\n")
        XCTAssertEqual(Array(TelegramMessagePresentation.plainText(hidden, revealingSpoilers: true).utf8), Array(plain.text.utf8))
    }
}
