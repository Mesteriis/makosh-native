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
        object["schemaVersion"] = 99
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

    func testReplyTargetChangesPreserveTextAndRejectStaleAcknowledgementABA() throws {
        var store = TelegramDraftStore()
        let target = TelegramComposerReplyTarget(peerID: 42, namespace: 0, messageID: 7, threadID: 9)
        let first = try XCTUnwrap(store.setReplyTarget(target, accountID: 1, chatID: 42))
        XCTAssertEqual(first.text, ""); XCTAssertEqual(first.replyTarget, target)
        XCTAssertNil(store.setReplyTarget(target, accountID: 1, chatID: 42))
        let typed = try XCTUnwrap(store.save("reply", accountID: 1, chatID: 42))
        XCTAssertEqual(typed.replyTarget, target)
        _ = store.setReplyTarget(nil, accountID: 1, chatID: 42)
        let restored = try XCTUnwrap(store.setReplyTarget(target, accountID: 1, chatID: 42))
        XCTAssertEqual(restored.text, "reply")
        XCTAssertNil(store.acknowledge(sentText: "reply", revision: typed.revision, accountID: 1, chatID: 42))
        let cleared = try XCTUnwrap(store.acknowledge(sentText: "reply", revision: restored.revision, accountID: 1, chatID: 42))
        XCTAssertEqual(cleared.text, ""); XCTAssertNil(cleared.replyTarget)
        let replyOnly = try XCTUnwrap(store.setReplyTarget(target, accountID: 1, chatID: 42))
        XCTAssertNotNil(store.acknowledge(sentText: "", revision: replyOnly.revision, accountID: 1, chatID: 42))
        XCTAssertNil(store.setReplyTarget(.init(peerID: 42, namespace: 0, messageID: 0), accountID: 1, chatID: 42))
        XCTAssertNil(store.snapshot(accountID: 2, chatID: 42))
    }

    func testKnownV1UpgradesOnSameTextSave() throws {
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "legacy")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        fields["schemaVersion"] = 1
        let legacy = try JSONDecoder().decode(TelegramComposerDraft.self, from: JSONSerialization.data(withJSONObject: fields))
        var store = TelegramDraftStore()
        XCTAssertTrue(store.restore(legacy, accountID: 1, chatID: 42, expectedRevision: nil))
        let upgraded = try XCTUnwrap(store.save("legacy", accountID: 1, chatID: 42))
        XCTAssertEqual(upgraded.schemaVersion, 2); XCTAssertNotEqual(upgraded.revision, legacy.revision)
    }
}
