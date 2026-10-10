import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func composerFixtureRaw(_ box: Postbox, chatID: Int64, data: Data?) -> Signal<Data?, NoError> {
    box.transaction { transaction in
        let key = PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(chatID))
        if let data { transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: data)) }
        return transaction.getPreferencesEntry(key: key)?.data
    }
}

@MainActor final class TelegramComposerDraftPostboxTests: XCTestCase {
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
    private func raw(_ box: Postbox, chat: Int64, data: Data? = nil) async -> Data? {
        let done = expectation(description: "Raw fixture preference transaction")
        var result: Data?
        let op = (composerFixtureRaw(box, chatID: chat, data: data) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { op.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return result
    }
    private func seedThenRelease(_ path: URL, draft: TelegramComposerDraft) async throws {
        let box = try await open(path)
        previousBox = box
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: draft.accountID)
        try await save(draft, to: repository).get()
        let loaded = try await load(draft.chatID, from: repository).get()
        XCTAssertEqual(loaded, draft)
    }

    func testRestartPreservesExactUnicodeAndEmptyTombstone() async throws {
        let path = try root()
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "😀 e\u{301}\n  trailing  ")
        try await seedThenRelease(path, draft: draft)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox, "The first public Postbox must be released before reopening")
        let box = try await open(path)
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let read = try await load(42, from: repository).get()
        XCTAssertEqual(read, draft)
        let empty = TelegramComposerDraft(accountID: 1, chatID: 42, text: "")
        try await save(empty, to: repository).get()
        let tombstone = try await load(42, from: repository).get()
        XCTAssertEqual(tombstone, empty)
    }

    func testAccountAndChatIsolationAndOversizeRefusal() async throws {
        let box = try await open(root())
        let one = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let other = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 2)
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "first")
        try await save(draft, to: one).get()
        let missing = try await load(43, from: one).get()
        XCTAssertNil(missing)
        if case .failure(.incompatibleData) = await load(42, from: other) {} else { XCTFail("Wrong account must not read") }
        let wrong = TelegramComposerDraft(accountID: 2, chatID: 42, text: "replace")
        if case .failure(.incompatibleData) = await save(wrong, to: other) {} else { XCTFail("Wrong account must not overwrite") }
        let oversized = TelegramComposerDraft(accountID: 1, chatID: 42, text: String(repeating: "😀", count: 16385))
        if case .failure(.incompatibleData) = await save(oversized, to: one) {} else { XCTFail("Oversize must fail") }
        let unchanged = try await load(42, from: one).get()
        XCTAssertEqual(unchanged, draft)
    }

    func testMalformedAndUnknownDataRemainUntouchedOnLoadAndSave() async throws {
        let box = try await open(root())
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let valid = try JSONEncoder().encode(TelegramComposerDraft(accountID: 1, chatID: 42, text: "future"))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        fields["schemaVersion"] = 99
        let unknown = Data("MakoshComposerDraft.v1\n".utf8) + (try JSONSerialization.data(withJSONObject: fields))
        for data in [Data([0xff, 0, 7]), Data("MakoshComposerDraft.v1\n{".utf8), unknown] {
            _ = await raw(box, chat: 42, data: data)
            if case .failure(.incompatibleData) = await load(42, from: repository) {} else { XCTFail("Unknown format must fail") }
            if case .failure(.incompatibleData) = await save(.init(accountID: 1, chatID: 42, text: "replacement"), to: repository) {} else { XCTFail("Unknown data must not be erased") }
            let unchanged = await raw(box, chat: 42)
            XCTAssertEqual(unchanged, data)
        }
    }

    func testImmediateWritesPreserveInvocationOrder() async throws {
        let box = try await open(root())
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let done = expectation(description: "Both writes complete"); done.expectedFulfillmentCount = 2
        let first = TelegramComposerDraft(accountID: 1, chatID: 42, text: "old")
        let second = TelegramComposerDraft(accountID: 1, chatID: 42, text: "new")
        repository.save(first) { result in if case .failure = result { XCTFail("Write failed") }; done.fulfill() }
        repository.save(second) { result in if case .failure = result { XCTFail("Write failed") }; done.fulfill() }
        await fulfillment(of: [done], timeout: 20)
        let latest = try await load(42, from: repository).get()
        XCTAssertEqual(latest, second)
    }
    func testReplyOnlySurvivesEncryptedReopenAndV1UpgradesWithoutChangingMarker() async throws {
        let path = try root()
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, text: "", replyTarget: .init(peerID: 42, namespace: 0, messageID: 7, threadID: 9))
        try await seedThenRelease(path, draft: draft)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let box = try await open(path)
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let reopened = try await load(42, from: repository).get()
        XCTAssertEqual(reopened, draft)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        fields["text"] = draft.text
        fields["schemaVersion"] = 1; fields.removeValue(forKey: "replyTarget")
        let marker = Data("MakoshComposerDraft.v1\n".utf8)
        _ = await raw(box, chat: 42, data: marker + (try JSONSerialization.data(withJSONObject: fields)))
        let loadedLegacy = try await load(42, from: repository).get()
        let legacy = try XCTUnwrap(loadedLegacy)
        XCTAssertEqual(legacy.schemaVersion, 1)
        var store = TelegramDraftStore()
        XCTAssertTrue(store.restore(legacy, accountID: 1, chatID: 42, expectedRevision: nil))
        let upgraded = try XCTUnwrap(store.save("", accountID: 1, chatID: 42))
        try await save(upgraded, to: repository).get()
        let savedBytes = await raw(box, chat: 42)
        let bytes = try XCTUnwrap(savedBytes)
        XCTAssertTrue(bytes.starts(with: marker))
        let latest = try await load(42, from: repository).get()
        XCTAssertEqual(latest, upgraded)
        fields["schemaVersion"] = 2
        fields["replyTarget"] = ["peerID": 42, "namespace": 0, "messageID": 0]
        let invalid = marker + (try JSONSerialization.data(withJSONObject: fields))
        _ = await raw(box, chat: 42, data: invalid)
        if case .failure(.incompatibleData) = await load(42, from: repository) {} else { XCTFail("Invalid target must fail") }
        if case .failure(.incompatibleData) = await save(upgraded, to: repository) {} else { XCTFail("Invalid existing data must remain") }
        let unchanged = await raw(box, chat: 42)
        XCTAssertEqual(unchanged, invalid)
    }
    func testSchemaTwoTextAndReplyUpgradeWithoutLosingTarget() async throws {
        let box = try await open(root())
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let text = "e\u{301} 😀 legacy", revision = UUID()
        let target = TelegramComposerReplyTarget(peerID: 42, namespace: 0, messageID: 7, threadID: 9)
        let fields: [String: Any] = [
            "schemaVersion": 2, "accountID": 1, "chatID": 42,
            "revision": revision.uuidString, "text": text,
            "replyTarget": ["peerID": 42, "namespace": 0, "messageID": 7, "threadID": 9]
        ]
        let marker = Data("MakoshComposerDraft.v1\n".utf8)
        _ = await raw(box, chat: 42, data: marker + (try JSONSerialization.data(withJSONObject: fields)))
        let loaded = try await load(42, from: repository).get()
        let legacy = try XCTUnwrap(loaded)
        XCTAssertEqual(legacy.schemaVersion, 2)
        XCTAssertEqual(legacy.revision, revision)
        XCTAssertEqual(Array(legacy.text.utf8), Array(text.utf8))
        XCTAssertEqual(legacy.input.selection, .init(location: text.utf16.count, length: 0))
        XCTAssertTrue(legacy.input.formattedText.entities.isEmpty)
        XCTAssertEqual(legacy.replyTarget, target)
        var store = TelegramDraftStore()
        XCTAssertTrue(store.restore(legacy, accountID: 1, chatID: 42, expectedRevision: nil))
        let upgraded = try XCTUnwrap(store.save(input: legacy.input, accountID: 1, chatID: 42))
        XCTAssertEqual(upgraded.schemaVersion, 4)
        XCTAssertNotEqual(upgraded.revision, revision)
        XCTAssertEqual(upgraded.input, legacy.input)
        XCTAssertEqual(upgraded.replyTarget, target)
        try await save(upgraded, to: repository).get()
        let persisted = try await load(42, from: repository).get()
        XCTAssertEqual(persisted, upgraded)
        let persistedBytes = await raw(box, chat: 42)
        XCTAssertTrue(try XCTUnwrap(persistedBytes).starts(with: marker))
    }
    func testRichSelectionReplySnapshotSurvivesEncryptedReopen() async throws {
        let path = try root()
        let input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "😀 bold", entities: [.init(offset: 3, length: 4, kind: .bold)]), selection: .init(location: 3, length: 4))
        let draft = TelegramComposerDraft(accountID: 1, chatID: 42, input: input, replyTarget: .init(peerID: 42, namespace: 0, messageID: 7))
        try await seedThenRelease(path, draft: draft)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        let box = try await open(path)
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let restored = try await load(42, from: repository).get()
        XCTAssertEqual(restored, draft)
    }
    func testTotalEncodedPayloadLimitRefusesWriteAndPreservesExistingRawBytes() async throws {
        let box = try await open(root())
        let repository = TelegramPostboxComposerDraftRepository(postbox: box, accountID: 1)
        let original = TelegramComposerDraft(accountID: 1, chatID: 42, text: "existing")
        try await save(original, to: repository).get()
        let existingBytes = await raw(box, chat: 42)
        let before = try XCTUnwrap(existingBytes)
        let largeURL = "https://example.invalid/" + String(repeating: "x", count: 530 * 1024)
        let formatted = try TelegramFormattedText(text: "x", entities: [.init(offset: 0, length: 1, kind: .textURL(url: largeURL))])
        let excessive = TelegramComposerDraft(accountID: 1, chatID: 42, input: try TelegramComposerInput(formattedText: formatted))
        XCTAssertLessThanOrEqual(excessive.text.utf8.count, TelegramComposerDraft.maximumTextBytes)
        XCTAssertGreaterThan(try JSONEncoder().encode(excessive).count, 512 * 1024)
        if case .failure = await save(excessive, to: repository) {} else { XCTFail("Encoded payload must be bounded") }
        let after = await raw(box, chat: 42)
        XCTAssertEqual(after, before)
        let retained = try await load(42, from: repository).get()
        XCTAssertEqual(retained, original)
    }
}
