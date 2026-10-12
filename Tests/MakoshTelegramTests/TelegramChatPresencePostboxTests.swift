import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func writeChatPresence(_ box: Postbox, peer: PeerId, status: UserPresenceStatus, activity: Int32) -> Signal<Void, NoError> {
    box.transaction { transaction in
        transaction.updatePeerPresencesInternal(presences: [peer: TelegramUserPresence(status: status, lastActivity: activity)], merge: { _, new in new })
    }
}

@MainActor final class TelegramChatPresencePostboxTests: XCTestCase {
    func testCombinedCachedPresenceUpdatesAssociatedChatAndStopsAfterDisposal() async throws {
        initializeAccountManagement()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Synthetic encrypted peer cache")
        var postbox: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: {
                if case let .postbox(box) = $0 { postbox = box; opened.fulfill() }
            })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let box = try XCTUnwrap(postbox)
        // MediaBox initializes two storage databases on separate queues. Wait
        // for both before teardown can remove this fixture's private directory.
        let storageReady = expectation(description: "Synthetic media stores initialized")
        storageReady.expectedFulfillmentCount = 2
        let storage = (box.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue)
            .start(next: { _ in storageReady.fulfill() })
        let cache = (box.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue)
            .start(next: { _ in storageReady.fulfill() })
        defer { storage.dispose(); cache.dispose() }
        await fulfillment(of: [storageReady], timeout: 20)

        let user = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(12345))
        let secret = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(67890))
        let sources = [user, secret].map { id in
            TelegramSearchChatPresenceSource(chat: TelegramChat(id: id.toInt64(), title: "Synthetic", preview: "", unreadCount: 0), presencePeerID: user)
        }
        var latest: [TelegramChat] = []
        var changed: XCTestExpectation? = expectation(description: "Initial missing cached presence")
        let initial = try XCTUnwrap(changed)
        var emissionCount = 0
        let reader = (telegramSearchChatPresenceSignal(postbox: box, sources: sources, accountID: 99, serverTimeOffset: { 10 })
            |> deliverOnMainQueue).start(next: { chats in
                latest = chats; emissionCount += 1
                if let pending = changed { changed = nil; pending.fulfill() }
            })
        defer { reader.dispose() }
        await fulfillment(of: [initial], timeout: 20)
        XCTAssertEqual(latest.map(\.id), [user.toInt64(), secret.toInt64()])
        XCTAssertTrue(latest.allSatisfy { $0.presence == nil })

        func update(_ status: UserPresenceStatus, activity: Int32) async {
            let observed = expectation(description: "Reactive combined presence update")
            let committed = expectation(description: "Presence transaction committed")
            changed = observed
            let writer = (writeChatPresence(box, peer: user, status: status, activity: activity) |> deliverOnMainQueue)
                .start(next: { committed.fulfill() })
            defer { writer.dispose() }
            await fulfillment(of: [committed, observed], timeout: 20)
        }
        await update(.present(until: 1000), activity: 900)
        for chat in latest {
            XCTAssertEqual(chat.presence?.accountID, 99)
            XCTAssertEqual(chat.presence?.peerID, chat.id)
            XCTAssertEqual(chat.presence?.expiresAt, Date(timeIntervalSince1970: 991))
        }
        await update(.none, activity: 0)
        XCTAssertTrue(latest.allSatisfy { $0.presence == nil })
        await update(.recently(isHidden: true), activity: 1200)
        XCTAssertEqual(latest.map { $0.presence?.expiresAt }, Array(repeating: Date(timeIntervalSince1970: 1221), count: 2))
        await update(.recently(isHidden: true), activity: 1300)
        XCTAssertEqual(latest.map { $0.presence?.expiresAt }, Array(repeating: Date(timeIntervalSince1970: 1321), count: 2))

        reader.dispose()
        let countBefore = emissionCount
        let noMore = expectation(description: "Disposed reader receives no updates")
        noMore.isInverted = true
        changed = noMore
        let finalWrite = expectation(description: "Update after disposal commits")
        let writer = (writeChatPresence(box, peer: user, status: .none, activity: 0) |> deliverOnMainQueue)
            .start(next: { finalWrite.fulfill() })
        defer { writer.dispose() }
        await fulfillment(of: [finalWrite], timeout: 20)
        await fulfillment(of: [noMore], timeout: 0.2)
        XCTAssertEqual(emissionCount, countBefore)
    }
}
