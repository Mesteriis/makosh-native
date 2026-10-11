import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func savedForwardTransaction<T>(_ box: Postbox, _ body: @escaping @Sendable (Transaction) -> T) -> Signal<T, NoError> {
    box.transaction(body)
}

private func savedForwardUser(_ id: Int64) -> TelegramUser {
    TelegramUser(id: PeerId(id), accessHash: nil, firstName: "Synthetic", lastName: nil,
        username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
        emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
        profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}
private func savedForwardSeed(_ box: Postbox, changed: Bool = false, protected: Bool = false) -> Signal<Void, NoError> {
    savedForwardTransaction(box) { transaction in
        transaction.updatePeersInternal([savedForwardUser(1), savedForwardUser(7)], update: { _, new in new })
        for number: Int32 in [1, 2] {
            let id = MessageId(peerId: PeerId(7), namespace: Namespaces.Message.Cloud, id: number)
            let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: 55, threadId: nil,
                timestamp: 100, flags: protected ? [.Incoming, .CopyProtected] : [.Incoming],
                tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: PeerId(7),
                text: changed && number == 2 ? "changed" : "source \(number)", attributes: [], media: [])
            if transaction.getMessage(id) == nil { _ = transaction.addMessages([message], location: .Random) }
            else { transaction.updateMessage(id) { _ in .update(message) } }
        }
    }
}
private func savedForwardRequest(_ box: Postbox) -> Signal<TelegramSavedMessagesForwardRequest, NoError> {
    savedForwardTransaction(box) { transaction in
        .init(contextID: UUID(), accountID: 1, sources: [Int32(1), 2].compactMap { number in
            transaction.getMessage(MessageId(peerId: PeerId(7), namespace: Namespaces.Message.Cloud, id: number)).map {
                .init(source: telegramMessageActionSource($0, accountID: 1, chatID: 7))
            }
        })
    }
}
/// StoreMessage fixture exercises transaction/receipt persistence, not live Account enqueue.
private func savedForwardSyntheticAccept(_ box: Postbox, request: TelegramSavedMessagesForwardRequest) -> Signal<Bool, NoError> {
    savedForwardTransaction(box) { transaction in
        guard telegramSavedForwardAdmission(transaction: transaction, accountID: 1, request: request) else { return false }
        var ids: [TelegramForwardQueueID] = []
        for source in request.sources {
            let unique = Int64.random(in: Int64.min...Int64.max)
            let message = StoreMessage(peerId: PeerId(1), namespace: Namespaces.Message.Local,
                globallyUniqueId: unique, groupingKey: nil, threadId: nil, timestamp: 100,
                flags: [.Unsent], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
                authorId: nil, text: "source \(source.messageID)", attributes: [], media: [])
            guard let id = transaction.addMessages([message], location: .Random)[unique] else { return false }
            ids.append(.init(peerID: id.peerId.toInt64(), namespace: id.namespace, messageID: id.id))
        }
        return telegramSavedForwardRecordAcceptance(transaction: transaction, accountID: 1, request: request, ids: ids)
    }
}
private struct SavedForwardObservation: Sendable {
    let record: TelegramSavedMessagesForwardRecord?
    let ordinaryBytes: Data?
    let queuedCount: Int
}
private func savedForwardObservation(_ box: Postbox) -> Signal<SavedForwardObservation?, NoError> {
    savedForwardTransaction(box) { transaction in
        guard case let .success(record) = telegramSavedForwardRead(transaction: transaction, accountID: 1) else { return nil }
        let count = (record?.acceptedIDs ?? []).filter {
            transaction.getMessage(MessageId(peerId: PeerId($0.peerID), namespace: $0.namespace, id: $0.messageID)) != nil
        }.count
        return .init(record: record, ordinaryBytes: transaction.getPreferencesEntry(key: PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(1)))?.data, queuedCount: count)
    }
}
@MainActor final class TelegramSavedMessagesForwardPostboxTests: XCTestCase {
    #if DEBUG
    func testProviderRecoversOwnedPostboxFromMainActor() async throws {
        let box = try await open()
        let provider = TelegramSyntheticSavedMessagesForwardProvider(postbox: box)
        let ready = expectation(description: "Provider recovers on MainActor")
        var recovered: Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>?
        let lease = provider.recover { result in recovered = result; ready.fulfill() }
        defer { lease.cancel() }
        await fulfillment(of: [ready], timeout: 20)
        guard case .success(nil) = try XCTUnwrap(recovered) else {
            return XCTFail("An empty owned Postbox has no pending Saved forward")
        }
    }
    func testProviderLostAcknowledgementRecoversReceiptWithoutDuplicateQueue() async throws {
        let box = try await open(), model = TelegramModel.syntheticPreview()
        model.selectedChatID = 10001
        XCTAssertTrue(model.beginMessageSelection(messageID: "synthetic:10001:130",
            contextID: model.messageActionContextID, windowID: try XCTUnwrap(model.historyWindowID)))
        let selected = try XCTUnwrap(model.messageSelection.session)
        let request = TelegramSavedMessagesForwardRequest(contextID: selected.contextID, accountID: -1,
            sources: selected.sources.map(TelegramComposerForwardSource.init(source:)))
        let ordinary = Data("independent Saved input and reply".utf8)
        let _: Void = try await value(savedForwardTransaction(box) { transaction in
            transaction.setPreferencesEntry(key: PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(10000)), value: PreferencesEntry(data: ordinary))
        })
        let provider = TelegramSyntheticSavedMessagesForwardProvider(postbox: box, loseAcknowledgement: true)
        let accepted = expectation(description: "Lost acknowledgement is uncertain")
        let submission = provider.submit(request: request) { if $0 == .uncertain { accepted.fulfill() } }
        defer { submission.cancel() }
        await fulfillment(of: [accepted], timeout: 20)
        let recovered = try await value(telegramSavedForwardRecover(postbox: box, accountID: -1)).get()
        let record = try XCTUnwrap(recovered)
        XCTAssertEqual(record.request, request); XCTAssertEqual(record.acceptedIDs?.count, 1)
        XCTAssertEqual(record.acceptedIDs?.first?.peerID, 10000)
        let duplicate = expectation(description: "Same operation is never queued again")
        let restarted = TelegramSyntheticSavedMessagesForwardProvider(postbox: box)
        let repeatSubmission = restarted.submit(request: request) { if $0 == .uncertain { duplicate.fulfill() } }
        defer { repeatSubmission.cancel() }
        await fulfillment(of: [duplicate], timeout: 20)
        let after = try await value(telegramSavedForwardRecover(postbox: box, accountID: -1)).get()
        XCTAssertEqual(after, record)
        let unchanged = try await value(savedForwardTransaction(box) { transaction in
            let history = transaction.getMessagesHistoryViewState(input: .single(peerId: PeerId(10000), threadId: nil),
                ignoreMessagesInTimestampRange: nil, ignoreMessageIds: [], count: 100, clipHoles: false,
                anchor: .upperBound, namespaces: .just([Namespaces.Message.Local]))
            return transaction.getPreferencesEntry(key: PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(10000)))?.data == ordinary
                && history.entries.count == 1 && history.entries.first?.message.id.id == record.acceptedIDs?.first?.messageID
        })
        XCTAssertTrue(unchanged)
    }
    #endif
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let ready = expectation(description: "Saved forward transaction"); var result: T?
        let lease = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; ready.fulfill() })
        defer { lease.dispose() }
        await fulfillment(of: [ready], timeout: 20); return try XCTUnwrap(result)
    }
    private func open(at existingRoot: URL? = nil) async throws -> Postbox {
        initializeAccountManagement()
        let root = existingRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("makosh-saved-forward-" + UUID().uuidString)
        if existingRoot == nil {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            addTeardownBlock { try FileManager.default.removeItem(at: root) }
        }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 41, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 42, count: 16)))
        let ready = expectation(description: "Encrypted Saved forward Postbox"); var result: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(box) = $0 { result = box; ready.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        let box = try XCTUnwrap(result), stores = expectation(description: "Both media stores")
        stores.expectedFulfillmentCount = 2
        let a = (box.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        let b = (box.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        defer { a.dispose(); b.dispose() }
        await fulfillment(of: [stores], timeout: 20); return box
    }
    func testSeparateQueueReceiptAndUnknownOrdinarySavedBytesSurviveGenuineReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-saved-reopen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let ordinary = Data("unknown ordinary Saved Messages input/reply/forward format".utf8)
        weak var previous: Postbox?
        do {
            let box = try await open(at: root); previous = box
            let _: Void = try await value(savedForwardSeed(box))
            let _: Void = try await value(savedForwardTransaction(box) { transaction in
                transaction.setPreferencesEntry(key: PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(1)), value: PreferencesEntry(data: ordinary))
            })
            let request = try await value(savedForwardRequest(box))
            let began = try await value(savedForwardTransaction(box) { telegramSavedForwardBegin(transaction: $0, accountID: 1, request: request) })
            XCTAssertTrue(began)
            let accepted = try await value(savedForwardSyntheticAccept(box, request: request)); XCTAssertTrue(accepted)
        }
        for _ in 0..<100 where previous != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previous); guard previous == nil else { return }
        let reopened = try await open(at: root), observed = try await value(savedForwardObservation(reopened))
        let state = try XCTUnwrap(observed)
        XCTAssertEqual(state.ordinaryBytes, ordinary); XCTAssertEqual(state.queuedCount, 2)
        XCTAssertEqual(state.record?.acceptedIDs?.count, 2)
        let original = try XCTUnwrap(state.record?.request)
        let duplicate = try await value(savedForwardTransaction(reopened) { telegramSavedForwardBegin(transaction: $0, accountID: 1, request: original) })
        XCTAssertFalse(duplicate, "Recovery never queues the same operation again")
    }
    func testPendingIntentBlocksReplacementAndRejectMustMatchExactRequest() async throws {
        let box = try await open(); let _: Void = try await value(savedForwardSeed(box))
        let first = try await value(savedForwardRequest(box)), second = try await value(savedForwardRequest(box))
        let results = try await value(savedForwardTransaction(box) { transaction in
            [telegramSavedForwardBegin(transaction: transaction, accountID: 1, request: first),
             telegramSavedForwardBegin(transaction: transaction, accountID: 1, request: second),
             telegramSavedForwardReject(transaction: transaction, accountID: 1, request: second),
             telegramSavedForwardAdmission(transaction: transaction, accountID: 1, request: first)]
        })
        XCTAssertEqual(results, [true, false, false, true])
        let rejected = try await value(savedForwardTransaction(box) { telegramSavedForwardReject(transaction: $0, accountID: 1, request: first) })
        XCTAssertTrue(rejected)
        let fresh = try await value(savedForwardTransaction(box) { telegramSavedForwardBegin(transaction: $0, accountID: 1, request: second) })
        XCTAssertTrue(fresh)
    }
    func testFinalFreshAdmissionRejectsChangedProtectedAndForeignBatchWithoutReceipt() async throws {
        for protected in [false, true] {
            let box = try await open(); let _: Void = try await value(savedForwardSeed(box))
            let request = try await value(savedForwardRequest(box))
            let began = try await value(savedForwardTransaction(box) { telegramSavedForwardBegin(transaction: $0, accountID: 1, request: request) }); XCTAssertTrue(began)
            let _: Void = try await value(savedForwardSeed(box, changed: !protected, protected: protected))
            let admitted = try await value(savedForwardTransaction(box) { telegramSavedForwardAdmission(transaction: $0, accountID: 1, request: request) })
            let foreign = try await value(savedForwardTransaction(box) { telegramSavedForwardAdmission(transaction: $0, accountID: 2, request: request) })
            XCTAssertFalse(admitted); XCTAssertFalse(foreign)
            let observed = try await value(savedForwardObservation(box)); XCTAssertNil(observed?.record?.acceptedIDs)
        }
    }
    func testUnknownReceiptBytesFailClosedAndArePreserved() async throws {
        let box = try await open(); let _: Void = try await value(savedForwardSeed(box))
        let request = try await value(savedForwardRequest(box)), bytes = Data("future-private-receipt-format".utf8)
        let preserved = try await value(savedForwardTransaction(box) { transaction in
            let key = telegramSavedForwardKey(accountID: 1)
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: bytes))
            let began = telegramSavedForwardBegin(transaction: transaction, accountID: 1, request: request)
            return !began && transaction.getPreferencesEntry(key: key)?.data == bytes
        })
        XCTAssertTrue(preserved)
    }
    func testInvalidQueueReceiptAndUnselectedAlbumExpansionAreRefused() async throws {
        let box = try await open(); let _: Void = try await value(savedForwardSeed(box))
        let request = try await value(savedForwardRequest(box))
        let result = try await value(savedForwardTransaction(box) { transaction -> [Bool] in
            let batch = telegramForwardBatch(transaction: transaction, accountID: 1, draft: request.draft)
            let exact = batch?.messages.count == 2
            let began = telegramSavedForwardBegin(transaction: transaction, accountID: 1, request: request)
            let receipt = telegramSavedForwardRecordAcceptance(transaction: transaction, accountID: 1, request: request,
                ids: [.init(peerID: 1, namespace: 1, messageID: 999)])
            return [exact, began, receipt]
        })
        XCTAssertEqual(result, [true, true, false])
    }
}
