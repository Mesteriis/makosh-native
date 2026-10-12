import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func seedPrivacyDirectory(_ box: Postbox) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peers = [1,7,8].map { number in
            TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(Int64(number))),
                accessHash: number == 8 ? .genericPublic(80) : .personal(70), firstName: "Synthetic", lastName: "Alice",
                username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil,
                usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
                profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        }
        transaction.updatePeersInternal(peers, update: { _, new in new })
        transaction.replaceContactPeerIds(Set(peers.map(\.id)))
    }
}
@MainActor final class TelegramPrivacyPostboxTests: XCTestCase {
    func testProductionDirectoryUsesActualEncryptedPostboxQueueAndFiltersUnusablePeers() async throws {
        initializeAccountManagement()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 7, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 8, count: 16)))
        let opened = expectation(description: "Synthetic encrypted privacy cache")
        var box: Postbox?
        let opening = (openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: .init(forceEncryptionIfNoSet: true, key: key, salt: salt), timestampForAbsoluteTimeBasedOperations: 1,
            isMainProcess: true, isTemporary: false, isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            |> deliverOnMainQueue).start(next: { if case let .postbox(value) = $0 { box = value; opened.fulfill() } })
        defer { opening.dispose() }
        await fulfillment(of: [opened], timeout: 20)
        let postbox = try XCTUnwrap(box)
        let storageReady = expectation(description: "Synthetic storage initialized"); storageReady.expectedFulfillmentCount = 2
        let storage = (postbox.mediaBox.storageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in storageReady.fulfill() })
        let cache = (postbox.mediaBox.cacheStorageBox.all() |> take(1) |> deliverOnMainQueue).start(next: { _ in storageReady.fulfill() })
        defer { storage.dispose(); cache.dispose() }
        await fulfillment(of: [storageReady], timeout: 20)
        let seeded = expectation(description: "Synthetic contacts committed")
        let seed = (seedPrivacyDirectory(postbox) |> deliverOnMainQueue).start(next: { seeded.fulfill() }); defer { seed.dispose() }
        await fulfillment(of: [seeded], timeout: 20)
        for query in ["", "Synthetic"] {
            let read = expectation(description: "Directory result")
            let request = (telegramPrivacySearch(postbox: postbox, accountID: 1, selfID: 1, query: query, include: [.user(7), .user(99)])
                |> deliverOnMainQueue).start(next: { value in
                    XCTAssertEqual(value.candidates.map(\.id), [.user(7)])
                    XCTAssertEqual(value.existing, [.init(id: .user(7), title: "Synthetic Alice")])
                    XCTAssertFalse(value.hasMore); read.fulfill()
                })
            await fulfillment(of: [read], timeout: 5); request.dispose()
        }
    }
}
