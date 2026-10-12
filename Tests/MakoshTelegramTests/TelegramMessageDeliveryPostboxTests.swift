import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func deliveryPeer(_ id: PeerId) -> TelegramUser {
    TelegramUser(id: id, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil)
}
private func seedDelivery(_ box: Postbox, peers: [PeerId]) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal(peers.map(deliveryPeer), update: { _, new in new })
        for peer in peers {
            transaction.resetIncomingReadStates([peer: [
                Namespaces.Message.Cloud: .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 1, count: 0, markedUnread: false),
                77: .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 1, count: 0, markedUnread: false)
            ]])
            for namespace: Int32 in [Namespaces.Message.Cloud, 77] {
                let message = StoreMessage(id: MessageId(peerId: peer, namespace: namespace, id: 1),
                    globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 100,
                    flags: [], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: nil,
                    text: "Immutable synthetic outgoing", attributes: [], media: [])
                _ = transaction.addMessages([message], location: .Random)
                // This fixture models a fully loaded local history, not a random
                // cached island surrounded by the production seed's cloud holes.
                transaction.removeHole(peerId: peer, threadId: nil, namespace: namespace,
                    space: .everywhere, range: 1...(Int32.max - 1))
            }
        }
        return true
    }
}
private func committedDelivery(_ box: Postbox, peer: PeerId) -> Signal<Message?, NoError> {
    box.transaction { $0.getMessage(MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1)) }
}
private func markDeliveryRead(_ box: Postbox, id: MessageId) -> Signal<Bool, NoError> {
    box.transaction { transaction in transaction.applyOutgoingReadMaxId(id); return true }
}
private func deliveryHistory(_ box: Postbox, peer: PeerId) -> Signal<(MessageHistoryView, ViewUpdateType, InitialMessageHistoryData?), NoError> {
    box.aroundMessageHistoryViewForLocation(.peer(peerId: peer, threadId: nil), anchor: .upperBound,
        ignoreMessagesInTimestampRange: nil, ignoreMessageIds: [], count: 20, trackHoles: false,
        fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tag: nil,
        appendMessagesFromTheSameGroup: false, namespaces: .all, orderStatistics: [])
}

@MainActor final class TelegramMessageDeliveryPostboxTests: XCTestCase {
    private weak var previousBox: Postbox?
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let done = expectation(description: "Delivery fixture transaction")
        var result: T?
        let operation = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; done.fulfill() })
        defer { operation.dispose() }
        await fulfillment(of: [done], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func open(_ path: URL) async throws -> Postbox {
        initializeAccountManagement()
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 9, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 10, count: 16)))
        let opened = expectation(description: "Encrypted delivery fixture")
        var box: Postbox?
        let opening = (openPostbox(basePath: path.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(value) = $0 { box = value; opened.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let result = try XCTUnwrap(box)
        _ = try await value(result.mediaBox.storageBox.all())
        _ = try await value(result.mediaBox.cacheStorageBox.all())
        return result
    }
    private func seedObserveAndRelease(_ path: URL, peer: PeerId, other: PeerId) async throws {
        let box = try await open(path); previousBox = box
        _ = try await value(seedDelivery(box, peers: [peer, other]))
        let committed = try await value(committedDelivery(box, peer: peer))
        XCTAssertNotNil(committed, "Seeded cloud message must survive the write transaction")
        XCTAssertTrue(committed?.peers[peer] is TelegramUser)
        let first = try await value(deliveryHistory(box, peer: peer)).0
        XCTAssertFalse(first.isLoading, "Complete synthetic history must not be clipped by seed holes")
        let initial = try XCTUnwrap(first.entries.first { $0.message.id.namespace == Namespaces.Message.Cloud })
        XCTAssertFalse(initial.isRead)
        XCTAssertEqual(TelegramMessage(initial, accountID: 999).delivery, .sent)
        let changed = expectation(description: "Same history subscription reacts to outgoing read update")
        var updated: MessageHistoryEntry?
        let subscription = (deliveryHistory(box, peer: peer) |> deliverOnMainQueue).start(next: { view, _, _ in
            if updated == nil, let entry = view.entries.first(where: { $0.message.id == initial.message.id && $0.isRead }) {
                updated = entry; changed.fulfill()
            }
        })
        defer { subscription.dispose() }
        _ = try await value(markDeliveryRead(box, id: initial.message.id))
        await fulfillment(of: [changed], timeout: 20)
        let read = try XCTUnwrap(updated)
        XCTAssertEqual(TelegramMessage(read, accountID: 999).delivery, .read)
        XCTAssertEqual(read.message.text, initial.message.text)
        XCTAssertEqual(read.message.stableVersion, initial.message.stableVersion)
        XCTAssertEqual(read.message.flags, initial.message.flags)
        XCTAssertFalse(initial.isRead, "The old immutable snapshot stays unchanged")
        let isolated = try await value(deliveryHistory(box, peer: peer)).0
        XCTAssertFalse(try XCTUnwrap(isolated.entries.first { $0.message.id.namespace == 77 }).isRead)
        let otherView = try await value(deliveryHistory(box, peer: other)).0
        XCTAssertTrue(otherView.entries.allSatisfy { !$0.isRead })
    }
    func testEncryptedOutgoingReadUpdateIsReactiveIsolatedAndSurvivesReopen() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(71))
        let other = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(72))
        try await seedObserveAndRelease(path, peer: peer, other: other)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox, "Release the first public Postbox before reopen")
        guard previousBox == nil else { return }
        let reopened = try await open(path)
        let view = try await value(deliveryHistory(reopened, peer: peer)).0
        let entry = try XCTUnwrap(view.entries.first { $0.message.id.namespace == Namespaces.Message.Cloud })
        XCTAssertTrue(entry.isRead)
        XCTAssertEqual(TelegramMessage(entry, accountID: 999).delivery, .read)
    }
}
