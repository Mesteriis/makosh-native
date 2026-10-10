import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func forwardTestBegin(_ box: Postbox, _ draft: TelegramComposerDraft) -> Signal<Bool, NoError> {
    box.transaction { telegramForwardBeginSubmission(transaction: $0, accountID: draft.accountID, draft: draft) }
}
private func forwardTestAccept(_ box: Postbox, _ draft: TelegramComposerDraft, _ ids: [TelegramForwardQueueID]) -> Signal<Bool, NoError> {
    box.transaction { telegramForwardRecordAcceptance(transaction: $0, accountID: draft.accountID, draft: draft, ids: ids) }
}
private func forwardTestRaw(_ box: Postbox, _ data: Data?) -> Signal<Data?, NoError> {
    box.transaction { transaction in
        let key = PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(42))
        if let data { transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: data)) }
        return transaction.getPreferencesEntry(key: key)?.data
    }
}
@MainActor final class TelegramForwardDraftTests: XCTestCase {
    private weak var previousBox: Postbox?
    private func open(_ root: URL) async throws -> Postbox {
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Encrypted draft fixture")
        var box: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(value) = $0 { box = value; opened.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let result = try XCTUnwrap(box)
        let ready = expectation(description: "Both MediaBox stores ready"); ready.expectedFulfillmentCount = 2
        let storage = (result.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        let cache = (result.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in ready.fulfill() })
        defer { storage.dispose(); cache.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return result
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func save(_ draft: TelegramComposerDraft, to repository: TelegramPostboxComposerDraftRepository) async -> Result<Void, TelegramComposerDraftPersistenceError> {
        let done = expectation(description: "Draft transaction completed")
        var result: Result<Void, TelegramComposerDraftPersistenceError> = .failure(.unavailable)
        repository.save(draft) { result = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 20)
        return result
    }
    private func load(_ chat: Int64, from repository: TelegramPostboxComposerDraftRepository) async -> Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError> {
        let done = expectation(description: "Draft loaded")
        var result: Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError> = .failure(.unavailable)
        let read = repository.load(chatID: chat) { result = $0; done.fulfill() }
        defer { read.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return result
    }

    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Forward transaction"); var result: T?
        let operation = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { operation.dispose() }; await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func intent(fingerprint: String = "e\u{301}", hideNames: Bool = false) -> TelegramComposerForwardIntent {
        .init(sources: [.init(chatID: 41, peerID: 41, namespace: Namespaces.Message.Cloud, messageID: 7, fingerprint: fingerprint)], hideNames: hideNames)
    }
    func testSchemaLegacyBoundsAndExactOpaqueSource() throws {
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "comment", forwardIntent: intent())
        XCTAssertTrue(draft.isValid); XCTAssertEqual(draft.schemaVersion, 4)
        XCTAssertEqual(try JSONDecoder().decode(TelegramComposerDraft.self, from: JSONEncoder().encode(draft)), draft)
        XCTAssertNotEqual(intent().sources, intent(fingerprint: "é").sources)
        let duplicate = TelegramComposerForwardIntent(sources: intent().sources + intent().sources)
        XCTAssertFalse(duplicate.isValid)
        XCTAssertFalse(TelegramComposerForwardIntent(sources: []).isValid)
        let hundred = (1...100).map { TelegramComposerForwardSource(chatID: 41, peerID: 41, namespace: Namespaces.Message.Cloud, messageID: Int32($0), fingerprint: "v1") }
        XCTAssertTrue(TelegramComposerForwardIntent(sources: hundred).isValid)
        XCTAssertFalse(TelegramComposerForwardIntent(sources: hundred + [.init(chatID: 41, peerID: 41, namespace: Namespaces.Message.Cloud, messageID: 101, fingerprint: "v1")]).isValid)
        XCTAssertFalse(intent(fingerprint: String(repeating: "a", count: 4097)).isValid)
        for version in 1...3 {
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TelegramComposerDraft(accountID: 1, chatID: 42, text: "legacy"))) as? [String: Any])
            fields["schemaVersion"] = version
            if version < 3 { fields["input"] = nil; fields["text"] = "legacy" }
            let loaded = try JSONDecoder().decode(TelegramComposerDraft.self, from: JSONSerialization.data(withJSONObject: fields))
            XCTAssertTrue(loaded.isValid); XCTAssertNil(loaded.forwardIntent)
        }
    }
    func testQueueBoundsAndFutureSchemaFailClosed() throws {
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "comment", forwardIntent: intent())
        let one = TelegramForwardQueueID(peerID: 42, namespace: Namespaces.Message.Local, messageID: 1)
        let two = TelegramForwardQueueID(peerID: 42, namespace: Namespaces.Message.Local, messageID: 2)
        XCTAssertTrue(draft.validForwardQueueIDs([one, two]))
        XCTAssertFalse(draft.validForwardQueueIDs([one])); XCTAssertFalse(draft.validForwardQueueIDs([one, one]))
        XCTAssertFalse(draft.validForwardQueueIDs([one, .init(peerID: 99, namespace: Namespaces.Message.Local, messageID: 2)]))
        XCTAssertFalse(draft.validForwardQueueIDs([one, .init(peerID: 42, namespace: Namespaces.Message.Cloud, messageID: 2)]))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        fields["schemaVersion"] = 99
        let future = try JSONDecoder().decode(TelegramComposerDraft.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertFalse(future.isValid)
    }
    func testStorePreservesReplyCommentAndRevisionDiscipline() throws {
        var store = TelegramDraftStore()
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "e\u{301} 😀", entities: [.init(offset: 0, length: 2, kind: .bold)]), selection: .init(location: 2, length: 0))
        _ = store.save(input: input, accountID: 1, chatID: 42)
        let reply = TelegramComposerReplyTarget(peerID: 42, namespace: Namespaces.Message.Cloud, messageID: 9)
        _ = store.setReplyTarget(reply, accountID: 1, chatID: 42)
        let first = try XCTUnwrap(store.setForwardIntent(intent(), accountID: 1, chatID: 42))
        XCTAssertEqual(first.replyTarget, reply); XCTAssertEqual(first.input, input)
        let options = TelegramComposerForwardIntent(id: first.forwardIntent!.id, sources: first.forwardIntent!.sources, hideNames: true)
        let changed = try XCTUnwrap(store.setForwardIntent(options, accountID: 1, chatID: 42)); XCTAssertNotEqual(first.revision, changed.revision)
        XCTAssertNil(store.acknowledge(sentInput: input, revision: first.revision, accountID: 1, chatID: 42))
        let selection = try TelegramComposerInput(formattedText: input.formattedText, selection: .init(location: 3, length: 0))
        let moved = try XCTUnwrap(store.save(input: selection, accountID: 1, chatID: 42)); XCTAssertNotEqual(changed.revision, moved.revision)
        let cancelled = try XCTUnwrap(store.setForwardIntent(nil, accountID: 1, chatID: 42))
        XCTAssertEqual(cancelled.input, selection); XCTAssertEqual(cancelled.replyTarget, reply)
        let started = TelegramComposerDraft(accountID: 1, chatID: 42, input: selection, forwardIntent: intent(), forwardDisposition: .submissionStarted)
        XCTAssertTrue(store.restore(started, accountID: 1, chatID: 42, expectedRevision: cancelled.revision))
        XCTAssertNil(store.save("overwrite", accountID: 1, chatID: 42)); XCTAssertNil(store.setReplyTarget(nil, accountID: 1, chatID: 42))
        XCTAssertNil(store.setForwardIntent(nil, accountID: 1, chatID: 42))
        XCTAssertNil(store.acknowledge(sentInput: selection, revision: started.revision, accountID: 1, chatID: 42))
    }
    func testEncryptedRejectionResetAndUnknownPayloadPreservation() async throws {
        let box = try await open(root()), repo = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "comment", forwardIntent: intent())
        try await save(draft, to: repo).get()
        let began = try await value(forwardTestBegin(box, draft)); XCTAssertTrue(began)
        let reset = try await value(telegramForwardResetRejected(postbox: box, accountID: 1, draft: draft)).get()
        XCTAssertEqual(reset, draft)
        let restarted = try await value(forwardTestBegin(box, reset)); XCTAssertTrue(restarted)
        let foreign = TelegramComposerDraft(accountID: 2, chatID: 42, input: draft.input, revision: draft.revision, forwardIntent: draft.forwardIntent)
        let refused = try await value(forwardTestBegin(box, foreign)); XCTAssertFalse(refused)
        let unknown = Data("unknown owner".utf8)
        let bytes = try await value(forwardTestRaw(box, unknown)); XCTAssertEqual(bytes, unknown)
        let bad = try await value(forwardTestBegin(box, draft)); XCTAssertFalse(bad)
        if case .failure = await save(draft, to: repo) {} else { XCTFail("Unknown bytes must survive ordinary save") }
        let retained = try await value(forwardTestRaw(box, nil)); XCTAssertEqual(retained, unknown)
    }
    private func seedAndAccept(_ path: URL, draft: TelegramComposerDraft) async throws {
        let box = try await open(path); previousBox = box
        let repo = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        try await save(draft, to: repo).get()
        let began = try await value(forwardTestBegin(box, draft)); XCTAssertTrue(began)
        let duplicate = try await value(forwardTestBegin(box, draft)); XCTAssertFalse(duplicate)
        let stale = TelegramComposerDraft(accountID: 1, chatID: 42, text: "overwrite")
        if case .failure = await save(stale, to: repo) {} else { XCTFail("Started pointer cannot be overwritten") }
        let invalid = try await value(forwardTestAccept(box, draft, [])); XCTAssertFalse(invalid)
        let ids = [TelegramForwardQueueID(peerID: 42, namespace: Namespaces.Message.Local, messageID: 1)]
        let accepted = try await value(forwardTestAccept(box, draft, ids)); XCTAssertTrue(accepted)
    }
    func testEncryptedAtomicTransitionsReopenAndConsume() async throws {
        let path = try root(), draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "", forwardIntent: intent())
        try await seedAndAccept(path, draft: draft)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let box = try await open(path), repo = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let loaded = try await load(42, from: repo).get()
        let accepted = try XCTUnwrap(loaded)
        XCTAssertEqual(accepted.revision, draft.revision)
        guard case .accepted = accepted.forwardDisposition else { return XCTFail("Durable queue receipt missing") }
        let staleReset = try await value(telegramForwardResetRejected(postbox: box, accountID: 1, draft: draft))
        if case .failure = staleReset {} else { XCTFail("Accepted cannot reset to prepared") }
        let consumed = try await value(telegramForwardConsumeAccepted(postbox: box, accountID: 1, draft: accepted)).get()
        XCTAssertNil(consumed.forwardIntent); XCTAssertEqual(consumed.input, .empty); XCTAssertNotEqual(consumed.revision, draft.revision)
        let repeated = try await value(telegramForwardConsumeAccepted(postbox: box, accountID: 1, draft: accepted))
        if case .failure = repeated {} else { XCTFail("Stale consume must fail") }
    }
}
