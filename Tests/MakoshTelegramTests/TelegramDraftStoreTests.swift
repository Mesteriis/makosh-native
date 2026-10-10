import XCTest
import Foundation
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
    func testExactBytesChangeRevisionAndFirstEmptyIsTombstone() throws {
        var store = TelegramDraftStore()
        let empty = try XCTUnwrap(store.save("",accountID: 1,chatID: 10))
        XCTAssertEqual(store.snapshot(accountID: 1,chatID: 10),empty)
        XCTAssertNil(store.save("",accountID: 1,chatID: 10))
        let a = try XCTUnwrap(store.save("é",accountID: 1,chatID: 10))
        XCTAssertNil(store.save("é",accountID: 1,chatID: 10))
        let b = try XCTUnwrap(store.save("e\u{301}",accountID: 1,chatID: 10))
        XCTAssertNotEqual(a.revision,b.revision)
        XCTAssertNotEqual(a,TelegramComposerDraft(accountID: 1,chatID: 10,text: b.text,revision: a.revision))
    }
    func testRevisionAcknowledgementRejectsABAAndClearsOnce() throws {
        var store = TelegramDraftStore()
        let sent = try XCTUnwrap(store.save("A",accountID: 1,chatID: 10))
        store.save("B",accountID: 1,chatID: 10)
        let newer = try XCTUnwrap(store.save("A",accountID: 1,chatID: 10))
        XCTAssertNil(store.acknowledge(sentText: "A",revision: sent.revision,accountID: 1,chatID: 10))
        XCTAssertEqual(store.snapshot(accountID: 1,chatID: 10),newer)
        let cleared = try XCTUnwrap(store.acknowledge(sentText: "A",revision: newer.revision,accountID: 1,chatID: 10))
        XCTAssertEqual(cleared.text,""); XCTAssertNotEqual(cleared.revision,newer.revision)
        XCTAssertNil(store.acknowledge(sentText: "A",revision: newer.revision,accountID: 1,chatID: 10))
        XCTAssertEqual(store.snapshot(accountID: 1,chatID: 10),cleared)
    }
    func testLateRestoreCannotOverwriteTypingOrExplicitClear() throws {
        var store = TelegramDraftStore()
        let remote = TelegramComposerDraft(accountID: 1,chatID: 10,text: "persisted")
        let typed = try XCTUnwrap(store.save("typed",accountID: 1,chatID: 10))
        XCTAssertFalse(store.restore(remote,accountID: 1,chatID: 10,expectedRevision: nil))
        store.save("",accountID: 1,chatID: 10)
        XCTAssertFalse(store.restore(remote,accountID: 1,chatID: 10,expectedRevision: typed.revision))
        XCTAssertEqual(store.draft(accountID: 1,chatID: 10),"")
        XCTAssertFalse(store.restore(nil,accountID: 1,chatID: 10,expectedRevision: store.snapshot(accountID: 1,chatID: 10)?.revision))
    }
    func testRestoreScopesSchemaAndSizeWithoutTruncation() throws {
        var store = TelegramDraftStore()
        let remote = TelegramComposerDraft(accountID: 1,chatID: 10,text: "  persisted\n")
        XCTAssertFalse(store.restore(remote,accountID: 2,chatID: 10,expectedRevision: nil))
        XCTAssertFalse(store.restore(remote,accountID: 1,chatID: 20,expectedRevision: nil))
        XCTAssertTrue(store.restore(remote,accountID: 1,chatID: 10,expectedRevision: nil))
        XCTAssertEqual(store.snapshot(accountID: 1,chatID: 10),remote)
        let maximum = TelegramComposerDraft(accountID: 2,chatID: 20,text: String(repeating: "x",count: 65536))
        XCTAssertTrue(maximum.isValid)
        let oversized = TelegramComposerDraft(accountID: 2,chatID: 20,text: maximum.text + "x")
        XCTAssertFalse(oversized.isValid)
        XCTAssertFalse(store.restore(oversized,accountID: 2,chatID: 20,expectedRevision: nil))
        let encoded = try JSONEncoder().encode(remote)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 2
        let future = try JSONDecoder().decode(TelegramComposerDraft.self,from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(future.isValid)
        XCTAssertFalse(store.restore(future,accountID: 1,chatID: 10,expectedRevision: remote.revision))
        XCTAssertEqual(store.snapshot(accountID: 1,chatID: 10),remote)
    }
    func testSnapshotCodableRoundTripRetainsEmptyAndExactUnicode() throws {
        for text in ["", "é", "e\u{301}", "😀\n  "] {
            let value = TelegramComposerDraft(accountID: -1,chatID: Int64.max,text: text)
            XCTAssertEqual(try JSONDecoder().decode(TelegramComposerDraft.self,from: JSONEncoder().encode(value)),value)
        }
    }

}
