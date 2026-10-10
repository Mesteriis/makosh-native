#if DEBUG
import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func selectionRangeSeed(_ box: Postbox, entries: [(Int32, Int32, Int32, Bool)]) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peer = PeerId(7)
        let user = TelegramUser(id: peer, accessHash: nil, firstName: "Synthetic", lastName: nil,
            username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
            emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
            profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([user], update: { _, new in new })
        let messages = entries.map { number, namespace, timestamp, protected in
            StoreMessage(id: MessageId(peerId: peer, namespace: namespace, id: number),
                globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: timestamp,
                flags: protected ? [.Incoming, .CopyProtected] : [.Incoming], tags: [], globalTags: [], localTags: [],
                forwardInfo: nil, authorId: peer, text: "Synthetic \(number):\(namespace)", attributes: [], media: [])
        }
        _ = transaction.addMessages(messages, location: .Random)
    }
}
private func selectionRangeIDs(_ box: Postbox, lower: Int32, upper: Int32, limit: Int, namespace: Int32 = 0) -> Signal<[MessageId], NoError> {
    box.transaction { transaction in
        transaction.makoshCachedMessageIds(peerId: PeerId(7), namespace: namespace,
            lowerBound: lower, upperBoundExclusive: upper, limit: limit)
    }
}

@MainActor final class TelegramSelectionRangeProviderTests: XCTestCase {
    private func value<T>(_ signal: Signal<T, NoError>) async throws -> T {
        let ready = expectation(description: "Synthetic range transaction")
        var result: T?
        let lease = (signal |> take(1) |> deliverOnMainQueue).start(next: { result = $0; ready.fulfill() })
        defer { lease.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        return try XCTUnwrap(result)
    }
    private func open() async throws -> Postbox {
        initializeAccountManagement()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-range-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 31, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 32, count: 16)))
        let ready = expectation(description: "Encrypted range Postbox")
        var result: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(box) = $0 { result = box; ready.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [ready], timeout: 20)
        let box = try XCTUnwrap(result), stores = expectation(description: "Both media stores initialized")
        stores.expectedFulfillmentCount = 2
        let a = (box.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        let b = (box.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in stores.fulfill() })
        defer { a.dispose(); b.dispose() }
        await fulfillment(of: [stores], timeout: 20)
        return box
    }
    private func selectionID(_ number: Int32, peer: Int64 = 7) -> TelegramMessageSelectionID {
        .init(source: .init(accountID: 1, chatID: 7, peerID: peer, namespace: 0, messageID: number,
            fingerprint: "Synthetic", text: "Synthetic", canReply: true, canEdit: false,
            canForward: true, canDeleteLocally: true, canDeleteForEveryone: false))
    }
    private func request(lower: Int32, upper: Int32, account: Int64 = 1, anchorPeer: Int64 = 7) -> TelegramMessageSelectionRangeRequest {
        .init(id: UUID(), sessionID: UUID(), revision: UUID(), contextID: UUID(), accountID: account, chatID: 7,
            anchorID: selectionID(lower, peer: anchorPeer), endpointID: selectionID(upper))
    }
    func testCachedIndexSparseHugeSpanIsExclusiveAndNumericNotTimestampOrdered() async throws {
        let box = try await open()
        let _: Void = try await value(selectionRangeSeed(box, entries: [(1, 0, 900, false), (12, 0, 800, false),
            (900_000_000, 0, 1, false), (1_000_000_000, 0, 50, false)]))
        let ids = try await value(selectionRangeIDs(box, lower: 1, upper: 1_000_000_000, limit: 200))
        XCTAssertEqual(ids.map(\.id), [900_000_000, 12, 1])
        let sources = try await value(telegramSelectionRange(postbox: box, accountID: 1,
            request: request(lower: 1, upper: 1_000_000_000)))
        XCTAssertEqual(sources.map(\.messageID), [900_000_000, 12, 1])
        XCTAssertTrue(sources.allSatisfy { $0.accountID == 1 && $0.chatID == 7 && $0.peerID == 7 })
    }
    func testCloudWinsEqualNumericLocalFallbackAndProtectedSourceRemains() async throws {
        let box = try await open()
        let _: Void = try await value(selectionRangeSeed(box, entries: [(2, Namespaces.Message.Cloud, 100, false),
            (2, Namespaces.Message.Local, 500, false), (3, Namespaces.Message.Local, 1, false),
            (4, Namespaces.Message.Cloud, 2, true)]))
        let sources = try await value(telegramSelectionRange(postbox: box, accountID: 1, request: request(lower: 1, upper: 5)))
        XCTAssertEqual(sources.map(\.messageID), [4, 3, 2])
        XCTAssertEqual(sources.map(\.namespace), [Namespaces.Message.Cloud, Namespaces.Message.Local, Namespaces.Message.Cloud])
        XCTAssertFalse(try XCTUnwrap(sources.first).canForward, "Range does not silently discard protected members")
    }
    func testShimRefusesInvalidLimitAndBoundsWithoutClamping() async throws {
        let box = try await open()
        let _: Void = try await value(selectionRangeSeed(box, entries: [(1, 0, 1, false)]))
        for limit in [0, -1, 201] {
            let ids = try await value(selectionRangeIDs(box, lower: 1, upper: 2, limit: limit))
            XCTAssertTrue(ids.isEmpty)
        }
        for bounds: (Int32, Int32) in [(2, 1), (1, 1)] {
            let ids = try await value(selectionRangeIDs(box, lower: bounds.0, upper: bounds.1, limit: 200))
            XCTAssertTrue(ids.isEmpty)
        }
    }
    func testProviderBoundAndForeignAccountPeerRefusal() async throws {
        let box = try await open()
        var entries: [(Int32, Int32, Int32, Bool)] = []
        for n in 1...230 {
            entries.append((Int32(n), Namespaces.Message.Cloud, Int32(500 - n), false))
            entries.append((Int32(n + 300), Namespaces.Message.Local, Int32(n), false))
        }
        let _: Void = try await value(selectionRangeSeed(box, entries: entries))
        let sources = try await value(telegramSelectionRange(postbox: box, accountID: 1, request: request(lower: 1, upper: 1000)))
        XCTAssertEqual(sources.count, 200)
        XCTAssertEqual(sources.map(\.messageID), Array((331...530).reversed()).map(Int32.init))
        let foreign = try await value(telegramSelectionRange(postbox: box, accountID: 1, request: request(lower: 1, upper: 1000, account: 2)))
        XCTAssertTrue(foreign.isEmpty)
        let migrated = try await value(telegramSelectionRange(postbox: box, accountID: 1, request: request(lower: 1, upper: 1000, anchorPeer: 8)))
        XCTAssertTrue(migrated.isEmpty, "No numeric range across different native peers")
    }
}
#endif
