import XCTest
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func topicDraftNative(_ box: Postbox, threadID: Int64?, text: String?, write: Bool) -> Signal<String?, NoError> {
    box.transaction { transaction in
        if write {
            let input = text.map { SynchronizeableChatInputState(replySubject: nil, text: $0, entities: [], timestamp: 100,
                textSelection: nil, messageEffectId: nil, suggestedPost: nil) }
            _internal_updateChatInputState(transaction: transaction, peerId: PeerId(42), threadId: threadID, inputState: input)
        }
        let state = threadID.flatMap { transaction.getPeerChatThreadInterfaceState(PeerId(42), threadId: $0) }
            ?? (threadID == nil ? transaction.getPeerChatInterfaceState(PeerId(42)) : nil)
        return state.flatMap { _internal_decodeStoredChatInterfaceState(state: $0)?.synchronizeableInputState?.text }
    }
}

@MainActor final class TelegramForumDraftTests: TelegramSourceFactsIntegrationTestCase {
    // Dropping selected topic identity would mix editor text or clear another
    // topic when an older asynchronous send acknowledgement arrives.
    func testTopicMemoryDraftsAndAcknowledgementsStayInTheirExactScope() throws {
        var store = TelegramDraftStore()
        let a = try XCTUnwrap(store.save("Topic A 😀", accountID: 1, chatID: 42, threadID: 1))
        _ = try XCTUnwrap(store.save("Topic B", accountID: 1, chatID: 42, threadID: 7))
        _ = try XCTUnwrap(store.save("All messages", accountID: 1, chatID: 42))
        XCTAssertEqual(store.snapshot(accountID: 1, chatID: 42, threadID: 1)?.text, "Topic A 😀")
        XCTAssertEqual(store.snapshot(accountID: 1, chatID: 42, threadID: 7)?.text, "Topic B")
        XCTAssertEqual(store.snapshot(accountID: 1, chatID: 42)?.text, "All messages")
        let cleared = store.acknowledge(sentInput: a.input, revision: a.revision, accountID: 1, chatID: 42, threadID: 1)
        XCTAssertEqual(cleared?.threadID, 1); XCTAssertEqual(cleared?.text, "")
        XCTAssertEqual(store.snapshot(accountID: 1, chatID: 42, threadID: 7)?.text, "Topic B")
        XCTAssertEqual(store.snapshot(accountID: 1, chatID: 42)?.text, "All messages")
    }
    func testTopicWireVersionRejectsDowngradeAndInvalidOrForeignReplyScope() throws {
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "Topic", threadID: 1)
        XCTAssertEqual(draft.schemaVersion, 6); XCTAssertEqual(draft.threadID, 1); XCTAssertTrue(draft.isValid)
        let encoded = try JSONEncoder().encode(draft)
        XCTAssertEqual(try JSONDecoder().decode(TelegramComposerDraft.self, from: encoded), draft)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        raw["schemaVersion"] = 4; raw["threadID"] = 1
        let old = try JSONDecoder().decode(TelegramComposerDraft.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertFalse(old.isValid, "Old versions cannot carry hidden topic identity")
        for id in [Int64(0), -1, Int64(Int32.max) + 1] {
            XCTAssertFalse(TelegramComposerDraft(accountID: 1, chatID: 42, text: "x", threadID: id).isValid)
        }
        let foreign = TelegramComposerDraft(accountID: 1, chatID: 42, text: "x", threadID: 1,
            replyTarget: .init(peerID: 42, namespace: 0, messageID: 8, threadID: 7))
        XCTAssertFalse(foreign.isValid)
        let ordinary = TelegramComposerDraft(accountID: 1, chatID: 42, text: "ordinary")
        let ordinaryJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary)) as? [String: Any])
        XCTAssertEqual(ordinary.schemaVersion, 4); XCTAssertNil(ordinaryJSON["threadID"])
    }
    func testTopicPostboxAndNativeServerDraftsDoNotOverwriteEachOtherOrCommonChat() async throws {
        let box = try await box(), repo = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        for (thread, text) in [(Int64?.none, "All messages"), (.some(1), "General"), (.some(7), "Design 😀")] {
            try await save(TelegramComposerDraft(accountID: 1, chatID: 42, text: text, threadID: thread), to: repo)
        }
        for (thread, text) in [(Int64?.none, "All messages"), (.some(1), "General"), (.some(7), "Design 😀")] {
            let restored = try await load(repo, threadID: thread)
            XCTAssertEqual(restored?.text, text); XCTAssertEqual(restored?.threadID, thread)
            let native = try await sourceFactsValue(topicDraftNative(box, threadID: thread, text: nil, write: false))
            XCTAssertEqual(native, text)
        }
    }
    func testRemoteTopicClearAndImportAreScopedAndRetainOtherTopicCursor() async throws {
        let box = try await box(), repo = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let first = TelegramComposerDraft(accountID: 1, chatID: 42, text: "General", threadID: 1)
        let second = TelegramComposerDraft(accountID: 1, chatID: 42, input: try .init(formattedText: .init(text: "Design 😀"), selection: .init(location: 3, length: 0)), threadID: 7)
        try await save(first, to: repo); try await save(second, to: repo)
        _ = try await sourceFactsValue(topicDraftNative(box, threadID: 1, text: nil, write: true))
        let empty = try await load(repo, threadID: 1)
        XCTAssertEqual(empty?.threadID, 1); XCTAssertEqual(empty?.text, "")
        let untouched = try await load(repo, threadID: 7)
        XCTAssertEqual(untouched, second)
        _ = try await sourceFactsValue(topicDraftNative(box, threadID: 1, text: "Remote general", write: true))
        let remote = try await load(repo, threadID: 1)
        XCTAssertEqual(remote?.text, "Remote general"); XCTAssertEqual(remote?.threadID, 1)
        let candidate = try await sourceFactsValue(topicCandidate(box, threadID: 7))
        XCTAssertNil(candidate)
    }
    private func box() async throws -> Postbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try await sourceFactsOpen(root.appendingPathComponent("postbox"))
    }
    private func save(_ draft: TelegramComposerDraft, to repo: TelegramPostboxComposerDraftRepository) async throws {
        let done = expectation(description: "Scoped topic write")
        var result: Result<Void, TelegramComposerDraftPersistenceError>?
        repo.save(draft) { result = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
        try XCTUnwrap(result).get()
    }
    private func load(_ repo: TelegramPostboxComposerDraftRepository, threadID: Int64?) async throws -> TelegramComposerDraft? {
        let done = expectation(description: "Scoped topic load")
        var result: Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>?
        let lease = repo.load(chatID: 42, threadID: threadID) { result = $0; done.fulfill() }
        defer { lease.dispose() }
        await fulfillment(of: [done], timeout: 10)
        return try XCTUnwrap(result).get()
    }
}
private nonisolated func topicCandidate(_ box: Postbox, threadID: Int64) -> Signal<TelegramServerDraftUpdate?, NoError> {
    box.transaction { try? telegramServerDraftUpdate(transaction: $0, accountID: 1, chatID: 42, threadID: threadID) }
}
