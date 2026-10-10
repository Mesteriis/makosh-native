import XCTest
@testable import MakoshTelegram

final class TelegramDraftStoreTests: XCTestCase {
    func testSwitchingConversationsRetainsEachDraft() {
        var store = TelegramDraftStore()
        store.save("Первый диалог", accountID: 1, chatID: 10)
        store.save("Второй диалог", accountID: 1, chatID: 20)
        XCTAssertEqual(store.draft(accountID: 1, chatID: 10), "Первый диалог")
        XCTAssertEqual(store.draft(accountID: 1, chatID: 20), "Второй диалог")
        XCTAssertEqual(store.draft(accountID: 1, chatID: 30), "")
    }

    func testSameChatIDInDifferentAccountsIsIsolated() {
        var store = TelegramDraftStore()
        store.save("Личный аккаунт", accountID: 1, chatID: 10)
        store.save("Рабочий аккаунт", accountID: 2, chatID: 10)
        store.acknowledge(sentText: "Личный аккаунт", accountID: 1, chatID: 10)
        XCTAssertEqual(store.draft(accountID: 1, chatID: 10), "")
        XCTAssertEqual(store.draft(accountID: 2, chatID: 10), "Рабочий аккаунт")
    }

    func testDelayedAcknowledgementPreservesNewTextAndOtherConversation() {
        var store = TelegramDraftStore()
        store.save("Отправленный текст", accountID: 1, chatID: 10)
        store.save("Другой диалог", accountID: 1, chatID: 20)
        store.save("Новый текст", accountID: 1, chatID: 10)
        store.acknowledge(sentText: "Отправленный текст", accountID: 1, chatID: 10)
        XCTAssertEqual(store.draft(accountID: 1, chatID: 10), "Новый текст")
        XCTAssertEqual(store.draft(accountID: 1, chatID: 20), "Другой диалог")
        store.acknowledge(sentText: "Новый текст", accountID: 1, chatID: 10)
        XCTAssertEqual(store.draft(accountID: 1, chatID: 10), "")
        XCTAssertEqual(store.draft(accountID: 1, chatID: 20), "Другой диалог")
    }

    func testEmptySaveRemovesOnlyItsDraftAndPreservesWhitespace() {
        var store = TelegramDraftStore()
        store.save("Удалить", accountID: 1, chatID: 10)
        store.save("  \n", accountID: 1, chatID: 20)
        store.save("", accountID: 1, chatID: 10)
        XCTAssertEqual(store.draft(accountID: 1, chatID: 10), "")
        XCTAssertEqual(store.draft(accountID: 1, chatID: 20), "  \n")
    }

    func testAcknowledgementPreservesNormalizationOnlyEdit() {
        var store = TelegramDraftStore()
        store.save("e\u{301}", accountID: 1, chatID: 10)
        store.acknowledge(sentText: "é", accountID: 1, chatID: 10)
        XCTAssertTrue(store.draft(accountID: 1, chatID: 10).utf8.elementsEqual("e\u{301}".utf8))
    }
}
