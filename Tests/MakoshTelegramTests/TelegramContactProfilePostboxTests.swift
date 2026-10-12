import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private func seedContactProfile(_ box: Postbox, peerID: PeerId, name: String = "Synthetic", about: String? = nil) -> Signal<Void, NoError> {
    box.transaction { transaction in
        let peer = TelegramUser(id: peerID, accessHash: nil, firstName: name, lastName: "Profile",
            username: "synthetic_profile", phone: "10000000000", photo: [], botInfo: nil,
            restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            subscriberCount: nil, verificationIconFileId: nil)
        transaction.updatePeersInternal([peer], update: { _, new in new })
        transaction.updatePeerCachedData(peerIds: [peerID], update: { _, _ in CachedUserData().withUpdatedAbout(about) })
    }
}

@MainActor final class TelegramContactProfilePostboxTests: XCTestCase {
    func testProductionPeerReaderRunsOnActualEncryptedPostboxQueue() async throws {
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
        let peerID = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(12345))
        let seeded = expectation(description: "Synthetic peer commits")
        let write = (seedContactProfile(box, peerID: peerID) |> deliverOnMainQueue).start(next: { seeded.fulfill() })
        defer { write.dispose() }
        await fulfillment(of: [seeded], timeout: 20)
        let read = expectation(description: "Production profile reader returns cached peer")
        var profile: TelegramContactProfile?
        let observedAt = Date(timeIntervalSince1970: 100)
        let reader = (telegramContactProfilePeer(postbox: box, peerID: peerID.toInt64())
            |> deliverOnMainQueue).start(next: { peer in
                profile = peer.flatMap { telegramContactProfile(peer: $0, accountID: 99, observedAt: observedAt) }
                read.fulfill()
            })
        defer { reader.dispose() }
        await fulfillment(of: [read], timeout: 20)
        XCTAssertEqual(profile?.displayName, "Synthetic Profile")
        XCTAssertEqual(profile?.username, "synthetic_profile")
        XCTAssertEqual(profile?.phone, "10000000000")
        XCTAssertEqual(profile?.accountID, 99); XCTAssertEqual(profile?.peerID, peerID.toInt64())
        XCTAssertEqual(profile?.observedAt, observedAt)
        let initialView = expectation(description: "Reactive initial profile")
        let changedView = expectation(description: "Reactive cached data and peer update")
        var sawInitial = false
        var sawChange = false
        let reactive = (box.peerView(id: peerID) |> deliverOnMainQueue).start(next: { view in
            guard let peer = view.peers[peerID], let value = telegramContactProfile(peer: peer,
                accountID: 99, observedAt: observedAt, cachedData: view.cachedData) else { return }
            if value.displayName == "Synthetic Profile", !sawInitial {
                sawInitial = true; initialView.fulfill()
            }
            if value.displayName == "Updated Profile", value.about == "Updated biography", !sawChange {
                sawChange = true; changedView.fulfill()
            }
        })
        defer { reactive.dispose() }
        await fulfillment(of: [initialView], timeout: 20)
        let updated = expectation(description: "Reactive profile update commits")
        let updater = (seedContactProfile(box, peerID: peerID, name: "Updated", about: "Updated biography")
            |> deliverOnMainQueue).start(next: { updated.fulfill() })
        defer { updater.dispose() }
        await fulfillment(of: [updated, changedView], timeout: 20)
        let missing = expectation(description: "Missing peer returns nil")
        let absent = (telegramContactProfilePeer(postbox: box, peerID: peerID.toInt64() + 1)
            |> deliverOnMainQueue).start(next: { peer in XCTAssertNil(peer); missing.fulfill() })
        defer { absent.dispose() }
        await fulfillment(of: [missing], timeout: 20)
    }
}
