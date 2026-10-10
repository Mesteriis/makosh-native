#if DEBUG
import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func syntheticForwardSnapshot(_ box: Postbox) -> Signal<(TelegramComposerDraft?, [MessageId]), NoError> {
    box.transaction { transaction in
        let loaded = try? telegramComposerDraftRead(transaction: transaction, accountID: -1, chatID: 10002).get()
        let view = transaction.getMessagesHistoryViewState(input: .single(peerId: PeerId(10002), threadId: nil),
            ignoreMessagesInTimestampRange: nil, ignoreMessageIds: [], count: 100, clipHoles: false,
            anchor: .upperBound, namespaces: .just([Namespaces.Message.Local]))
        return (loaded ?? nil, view.entries.map { $0.message.id })
    }
}
@MainActor final class TelegramSyntheticForwardTests: XCTestCase {
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
        let done = expectation(description: "Snapshot"); var result: T?
        let lease = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { lease.dispose() }; await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func draft() throws -> TelegramComposerDraft {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        let item = try XCTUnwrap(model.messages.last)
        let source = try XCTUnwrap(model.actionSource(for: item))
        return .init(accountID: -1, chatID: 10002, text: "synthetic comment", forwardIntent: .init(sources: [.init(source: source)]))
    }
    private func events(_ provider: TelegramSyntheticForwardProvider, draft: TelegramComposerDraft) async -> [String] {
        let done = expectation(description: "Terminal synthetic event"); var events: [String] = []
        let lease = provider.submit(draft: draft) { event in
            switch event {
            case .committing: events.append("committing")
            case .receiptAccepted: events.append("receiptAccepted")
            case .accepted: events.append("accepted"); done.fulfill()
            case .rejected: events.append("rejected"); done.fulfill()
            case .uncertain: events.append("uncertain"); done.fulfill()
            }
        }
        defer { lease.cancel() }; await fulfillment(of: [done], timeout: 20)
        return events
    }
    func testReceiptRefusalAfterActualWritesRetainsStartedAndDuplicateCannotEnqueue() async throws {
        let box = try await open(root()), draft = try draft()
        let repo = TelegramPostboxComposerDraftRepository(postbox: box, accountID: -1)
        try await save(draft, to: repo).get()
        let provider = TelegramSyntheticForwardProvider(postbox: box, simulateReceiptRefusal: true)
        let first = await events(provider, draft: draft); XCTAssertEqual(first, ["uncertain"])
        let started = try await value(syntheticForwardSnapshot(box))
        XCTAssertEqual(started.0?.forwardDisposition, .submissionStarted)
        XCTAssertEqual(started.1.count, 2, "Comment and forwarded synthetic message were really stored")
        let duplicate = await events(provider, draft: draft); XCTAssertEqual(duplicate, ["rejected"])
        let unchanged = try await value(syntheticForwardSnapshot(box))
        XCTAssertEqual(unchanged.0, started.0); XCTAssertEqual(unchanged.1, started.1)
    }
    func testLostAcknowledgementRecoversAcceptedReceiptWithoutAnotherMessage() async throws {
        let box = try await open(root()), draft = try draft()
        try await save(draft, to: TelegramPostboxComposerDraftRepository(postbox: box, accountID: -1)).get()
        let provider = TelegramSyntheticForwardProvider(postbox: box, loseAcknowledgement: true)
        let result = await events(provider, draft: draft); XCTAssertEqual(result, ["committing", "uncertain"])
        let snapshot = try await value(syntheticForwardSnapshot(box)), accepted = try XCTUnwrap(snapshot.0)
        guard case .accepted = accepted.forwardDisposition else { return XCTFail("Receipt must survive lost UI ACK") }
        XCTAssertEqual(snapshot.1.count, 2)
        let done = expectation(description: "Consume only"); var cleared: TelegramComposerDraft?
        let lease = provider.consumeAccepted(draft: accepted) { cleared = $0; done.fulfill() }
        defer { lease.cancel() }; await fulfillment(of: [done], timeout: 20)
        XCTAssertNil(try XCTUnwrap(cleared).forwardIntent)
        let after = try await value(syntheticForwardSnapshot(box)); XCTAssertEqual(after.1, snapshot.1)
        XCTAssertNil(after.0?.forwardIntent)
    }
}
#endif
