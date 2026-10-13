import XCTest
import AppKit
@testable import MakoshApp
import MakoshTelegram

@MainActor final class TelegramMessageReadingTextTests: XCTestCase {
    func testIdenticalReadingRefreshKeepsCurrentNativeMenuActionButChangedPermissionRevokesIt() throws {
        let value = try TelegramFormattedText(text: "secret source"), key = TelegramMessagePresentationKey(context: "account/secret/session/message", value: value)
        let text = TelegramMessageReadingText(frame: .zero); var called = 0
        func install(_ enabled: Bool) {
            text.install(presentation: TelegramMessagePresentation.attributedString(value), value: value, key: key,
                canCopy: true, actions: [.init(title: "Ответить", enabled: enabled, perform: { called += 1 })])
        }
        install(true)
        let current = try XCTUnwrap(text.readingMenu().items.first { $0.title == "Ответить" })
        install(true)
        _ = try XCTUnwrap(current.target as? NSObject).perform(try XCTUnwrap(current.action), with: current)
        XCTAssertEqual(called, 1, "An unchanged view update must not discard an open menu action")
        let revoked = try XCTUnwrap(text.readingMenu().items.first { $0.title == "Ответить" })
        install(false)
        _ = try XCTUnwrap(revoked.target as? NSObject).perform(try XCTUnwrap(revoked.action), with: revoked)
        XCTAssertEqual(called, 1, "Changed authority must still revoke the captured menu")
    }
    func testNativeSelectionRebasesBlockRangeAndKeepsQuoteableFormatting() throws {
        let full = try TelegramFormattedText(text: "prefix 😀 bold suffix", entities: [.init(offset: 7, length: 7, kind: .bold)])
        let part = try TelegramFormattedText(text: "😀 bold", entities: [.init(offset: 0, length: 7, kind: .bold)])
        let key = TelegramMessagePresentationKey(context: "account/chat/message-v1", value: full)
        let text = TelegramMessageReadingText(frame: .zero)
        var received: TelegramReplyQuote?
        text.install(presentation: TelegramMessagePresentation.attributedString(part), value: part,
            key: key, offset: 7, canCopy: true, quote: { received = $0 })
        XCTAssertEqual(text.string, part.text)
        text.setSelectedRange(NSRange(location: 0, length: 7))
        let selected = try XCTUnwrap(text.selectedQuote())
        XCTAssertEqual(selected.selection, .init(location: 7, length: 7))
        XCTAssertEqual(selected.formattedText.entities, part.entities)
        text.performQuote(); XCTAssertEqual(received, selected)
    }
    func testHiddenSpoilerAndProtectedTextCannotCreateQuoteOrExposeSourceInCopy() throws {
        let value = try TelegramFormattedText(text: "visible secret", entities: [.init(offset: 8, length: 6, kind: .spoiler)])
        let key = TelegramMessagePresentationKey(context: "synthetic", value: value), text = TelegramMessageReadingText(frame: .zero)
        text.install(presentation: TelegramMessagePresentation.attributedString(value), value: value, key: key, canCopy: true, quote: { _ in XCTFail("Hidden text must not be quoted") })
        XCTAssertEqual(text.string, "visible ██████")
        text.setSelectedRange(.init(location: 8, length: 6)); XCTAssertNil(text.selectedQuote())
        text.install(presentation: TelegramMessagePresentation.attributedString(value, revealingSpoilers: true), value: value, key: key, canCopy: false, revealingSpoilers: true)
        XCTAssertFalse(text.isSelectable); XCTAssertNil(text.selectedQuote())
    }
    func testContextChangeInvalidatesNativeSelectionAndOldMenuCallbacks() throws {
        let value = try TelegramFormattedText(text: "selected"), text = TelegramMessageReadingText(frame: .zero)
        let first = TelegramMessagePresentationKey(context: "first", value: value), second = TelegramMessagePresentationKey(context: "second", value: value)
        text.install(presentation: TelegramMessagePresentation.attributedString(value), value: value, key: first, canCopy: true, quote: { _ in XCTFail("Old action") })
        text.setSelectedRange(.init(location: 0, length: 8))
        let oldMenu = text.readingMenu(), oldQuote = oldMenu.items.first { $0.title == "Цитировать" }
        var callbacks = 0
        text.install(presentation: TelegramMessagePresentation.attributedString(value), value: value, key: second, canCopy: true, quote: { _ in callbacks += 1 })
        XCTAssertEqual(text.selectedRange().length, 0)
        if let item = oldQuote, let action = item.action { _ = (item.target as? NSObject)?.perform(action, with: item) }
        XCTAssertEqual(callbacks, 0)
        text.setSelectedRange(.init(location: 0, length: 8)); text.performQuote(); XCTAssertEqual(callbacks, 1)
    }
    func testMenuRetainsMessageActionsAndCopyPermission() throws {
        let value = try TelegramFormattedText(text: "source"), key = TelegramMessagePresentationKey(context: "synthetic", value: value)
        let text = TelegramMessageReadingText(frame: .zero)
        var actions = 0
        text.install(presentation: TelegramMessagePresentation.attributedString(value), value: value, key: key, canCopy: true,
            actions: [.init(title: "Ответить", enabled: true, perform: { actions += 1 }), .init(title: "Удалить", enabled: false, perform: { XCTFail() })], quote: { _ in })
        text.setSelectedRange(.init(location: 0, length: 6))
        let menu = text.readingMenu()
        XCTAssertNotNil(menu.items.first { $0.title == "Цитировать" && $0.isEnabled })
        XCTAssertNotNil(menu.items.first { $0.title == "Копировать" && $0.isEnabled })
        let reply = try XCTUnwrap(menu.items.first { $0.title == "Ответить" })
        if let action = reply.action { _ = (reply.target as? NSObject)?.perform(action, with: reply) }
        XCTAssertEqual(actions, 1); XCTAssertEqual(menu.items.first { $0.title == "Удалить" }?.isEnabled, false)
    }
    func testPreTrimQuoteLimitAndInvalidBlockBindingDenyQuote() throws {
        let value = try TelegramFormattedText(text: " x "), key = TelegramMessagePresentationKey(context: "synthetic", value: value), text = TelegramMessageReadingText(frame: .zero)
        text.install(presentation: TelegramMessagePresentation.attributedString(value), value: value, key: key, canCopy: true, maximumQuoteLength: 1, quote: { _ in XCTFail() })
        text.setSelectedRange(.init(location: 0, length: 3)); XCTAssertNil(text.selectedQuote())
        let wrong = try TelegramFormattedText(text: "abc")
        text.install(presentation: TelegramMessagePresentation.attributedString(wrong), value: wrong, key: key, canCopy: true, quote: { _ in XCTFail() })
        text.setSelectedRange(.init(location: 0, length: 3)); XCTAssertNil(text.selectedQuote())
    }
}
