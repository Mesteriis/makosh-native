import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func incomingReadPeer(_ id: PeerId) -> TelegramUser {
    TelegramUser(id: id, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
        photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
        nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
        subscriberCount: nil, verificationIconFileId: nil)
}
private func seedIncomingRead(_ box: Postbox, peers: [PeerId]) -> Signal<Bool, NoError> {
    box.transaction { transaction in
        transaction.updatePeersInternal(peers.map(incomingReadPeer), update: { _, new in new })
        for peer in peers {
            transaction.resetIncomingReadStates([peer: [
                Namespaces.Message.Cloud: .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 2, count: 1, markedUnread: false),
                77: .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 1, count: 1, markedUnread: false)
            ]])
            for namespace: Int32 in [Namespaces.Message.Cloud, 77] {
                let message = StoreMessage(id: MessageId(peerId: peer, namespace: namespace, id: 1),
                    globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 100,
                    flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: nil,
                    text: "Immutable synthetic incoming", attributes: [], media: [])
                _ = transaction.addMessages([message], location: .Random)
                // This fixture models a fully loaded local history, not a random
                // cached island surrounded by the production seed's cloud holes.
                transaction.removeHole(peerId: peer, threadId: nil, namespace: namespace,
                    space: .everywhere, range: 1...(Int32.max - 1))
                if namespace == Namespaces.Message.Cloud {
                    // An ordinary outgoing row is a valid visible read boundary
                    // for incoming messages preceding it.
                    _ = transaction.addMessages([StoreMessage(id: MessageId(peerId: peer, namespace: namespace, id: 2),
                        globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: 101, flags: [],
                        tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: nil,
                        text: "Synthetic outgoing boundary", attributes: [], media: [])], location: .Random)
                }
            }
        }
        return true
    }
}
private func committedIncomingRead(_ box: Postbox, peer: PeerId) -> Signal<Message?, NoError> {
    box.transaction { $0.getMessage(MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1)) }
}
private func applyIncomingRead(_ box: Postbox, peer: PeerId) -> Signal<[MessageId], NoError> {
    box.transaction { transaction in
        transaction.applyInteractiveReadMaxIndex(MessageIndex(id: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 2), timestamp: 101))
    }
}
private func incomingReadState(_ box: Postbox, peer: PeerId) -> Signal<CombinedPeerReadState?, NoError> {
    box.transaction { $0.getCombinedPeerReadState(peer) }
}
private func incomingJournal(_ box: Postbox) -> Signal<Result<[UUID], Error>, NoError> {
    box.transaction { transaction in Result { try transaction.makoshArchiveJournal(limit: 100).map(\.eventID) } }
}
private func incomingReadHistory(_ box: Postbox, peer: PeerId) -> Signal<(MessageHistoryView, ViewUpdateType, InitialMessageHistoryData?), NoError> {
    box.aroundMessageHistoryViewForLocation(.peer(peerId: peer, threadId: nil), anchor: .upperBound,
        ignoreMessagesInTimestampRange: nil, ignoreMessageIds: [], count: 20, trackHoles: false,
        fixedCombinedReadStates: nil, topTaggedMessageIdNamespaces: [], tag: nil,
        appendMessagesFromTheSameGroup: false, namespaces: .all, orderStatistics: [])
}

@MainActor final class TelegramHistoryReadPostboxTests: XCTestCase {
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
    private func seedReadAndRelease(_ path: URL, peer: PeerId, other: PeerId) async throws {
        let box = try await open(path); previousBox = box
        _ = try await value(seedIncomingRead(box, peers: [peer, other]))
        let unwrappedoriginal = try await value(committedIncomingRead(box, peer: peer))
        let original = try XCTUnwrap(unwrappedoriginal)
        let unwrappedbefore = try await value(incomingReadState(box, peer: peer))
        let before = try XCTUnwrap(unwrappedbefore)
        XCTAssertEqual(before.count, 2)
        let journal = try await value(incomingJournal(box)).get()
        let changed = expectation(description: "Reactive incoming read synchronization")
        var observed = false
        let subscription = (box.synchronizePeerReadStatesView() |> deliverOnMainQueue).start(next: { view in
            if !observed, case .Push? = view.operations[peer] { observed = true; changed.fulfill() }
        })
        defer { subscription.dispose() }
        _ = try await value(applyIncomingRead(box, peer: peer))
        await fulfillment(of: [changed], timeout: 20)
        let unwrappedafter = try await value(incomingReadState(box, peer: peer))
        let after = try XCTUnwrap(unwrappedafter)
        XCTAssertEqual(after.count, 0)
        // Native interactive read intentionally advances other namespaces through
        // the selected timestamp. This is not an independent-per-namespace API.
        for namespace: Int32 in [Namespaces.Message.Cloud, 77] {
            guard case let .idBased(maxIncoming, _, _, _, _)? = after.states.first(where: { $0.0 == namespace })?.1 else {
                XCTFail("Missing synthetic namespace state"); continue
            }
            XCTAssertEqual(maxIncoming, namespace == Namespaces.Message.Cloud ? 2 : 1)
        }
        let unwrappeduntouched = try await value(incomingReadState(box, peer: other))
        let untouched = try XCTUnwrap(unwrappeduntouched)
        XCTAssertEqual(untouched.count, 2)
        let unwrappedcurrent = try await value(committedIncomingRead(box, peer: peer))
        let current = try XCTUnwrap(unwrappedcurrent)
        XCTAssertEqual(current.text, original.text); XCTAssertEqual(current.stableVersion, original.stableVersion)
        let afterJournal = try await value(incomingJournal(box)).get()
        XCTAssertEqual(afterJournal, journal, "Reading must not manufacture content versions")
        _ = try await value(applyIncomingRead(box, peer: peer))
        let unwrappedrepeated = try await value(incomingReadState(box, peer: peer))
        let repeated = try XCTUnwrap(unwrappedrepeated)
        XCTAssertEqual(repeated, after)
    }
    func testEncryptedInteractiveIncomingReadPersistsAndPreservesContent() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(81))
        let other = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(82))
        try await seedReadAndRelease(path, peer: peer, other: other)
        for _ in 0..<100 where previousBox != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(previousBox)
        guard previousBox == nil else { return }
        let box = try await open(path)
        let unwrappedstate = try await value(incomingReadState(box, peer: peer))
        let state = try XCTUnwrap(unwrappedstate)
        XCTAssertEqual(state.count, 0)
        let unwrappedotherState = try await value(incomingReadState(box, peer: other))
        let otherState = try XCTUnwrap(unwrappedotherState)
        XCTAssertEqual(otherState.count, 2)
        let sync = try await value(box.synchronizePeerReadStatesView())
        guard case .Push? = sync.operations[peer] else { return XCTFail("Pending read sync must survive restart: \(String(describing: sync.operations[peer]))") }
    }
}
