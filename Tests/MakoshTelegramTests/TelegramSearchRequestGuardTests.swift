import XCTest
import Postbox
@testable import TelegramCore

private nonisolated func searchGuardUser(_ number: Int64, hasHash: Bool = true) -> TelegramUser {
    TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(number)),
        accessHash: hasHash ? .personal(100) : nil, firstName: "Synthetic", lastName: nil,
        username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
        emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
        profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}

private nonisolated func searchGuardChannel(monoforum: Bool = false) -> TelegramChannel {
    TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(43)),
        accessHash: .personal(101), title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
        participationStatus: .member, info: .group(.init(flags: [])),
        flags: monoforum ? [.isMonoforum] : [.isForum], restrictionInfo: nil, adminRights: nil,
        bannedRights: nil, defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil,
        backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil,
        approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil,
        sendPaidMessageStars: nil, linkedMonoforumId: nil)
}

final class TelegramSearchRequestGuardTests: XCTestCase {
    private func valid(peer: Peer = searchGuardChannel(), fromId: PeerId? = nil, from: Peer? = nil,
                       threadId: Int64? = nil, subPeer: Peer? = nil) -> Bool {
        makoshSearchInputIsValid(peer: peer, accountPeerId: searchGuardUser(1).id,
            fromId: fromId, from: from, threadId: threadId, subPeer: subPeer)
    }

    func testOrdinarySearchStillRequiresResolvableDestination() {
        XCTAssertTrue(valid())
        XCTAssertFalse(valid(peer: searchGuardUser(42, hasHash: false)))
    }

    func testMissingRequestedSenderCannotBecomeUnfilteredSearch() {
        XCTAssertFalse(valid(fromId: searchGuardUser(42).id))
    }

    func testDifferentResolvedSenderCannotReplaceRequestedIdentity() {
        XCTAssertFalse(valid(fromId: searchGuardUser(42).id, from: searchGuardUser(44)))
    }

    func testRequestedSenderWithoutAPIInputCannotBecomeUnfilteredSearch() {
        let sender = searchGuardUser(42, hasHash: false)
        XCTAssertFalse(valid(fromId: sender.id, from: sender))
    }

    func testExactResolvableSenderRemainsSupported() {
        let sender = searchGuardUser(42)
        XCTAssertTrue(valid(fromId: sender.id, from: sender))
    }

    func testOrdinaryThreadMustFitExactlyWithoutClamping() {
        for id in [Int64(0), -1, Int64(Int32.max) + 1, Int64.max] {
            XCTAssertFalse(valid(threadId: id), "Invalid thread \(id) must not be clamped to another topic")
        }
        XCTAssertTrue(valid(threadId: 1))
        XCTAssertTrue(valid(threadId: Int64(Int32.max)))
    }

    func testSavedAndMonoforumThreadsRequireExactResolvableSubPeer() {
        let subPeer = searchGuardUser(42)
        let destinations: [Peer] = [searchGuardUser(1), searchGuardChannel(monoforum: true)]
        for destination in destinations {
            let threadId = subPeer.id.toInt64()
            XCTAssertFalse(valid(peer: destination, threadId: threadId))
            XCTAssertFalse(valid(peer: destination, threadId: threadId, subPeer: searchGuardUser(44)))
            XCTAssertFalse(valid(peer: destination, threadId: threadId, subPeer: searchGuardUser(42, hasHash: false)))
            XCTAssertTrue(valid(peer: destination, threadId: threadId, subPeer: subPeer))
            XCTAssertFalse(valid(peer: destination, threadId: 0))
            XCTAssertFalse(valid(peer: destination, threadId: 0x0000000700000000))
        }
    }

    func testPackedSubPeerValidationRejectsUnsafeOrUnsupportedNamespacesBeforeConstruction() {
        for raw in [Int64(0), 0x0000000100000000, 0x0000000200000000,
                    0x0000000300000015, 0x0000000700000000, 0x7fffffff00000000, -1, Int64.max,
                    (Int64(1) << 59) | 42, (Int64(1) << 60) | 42, Int64.min | 42] {
            XCTAssertNil(makoshSearchSubPeerId(raw), "Unsupported packed peer \(raw) must be rejected safely")
        }
        let peers = [searchGuardUser(42).id,
            PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(55)),
            searchGuardChannel().id,
            PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(1 << 40)),
            PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(1 << 55)),
            PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value((Int64(1) << 56) - 1))]
        for peer in peers {
            XCTAssertEqual(makoshSearchSubPeerId(peer.toInt64()), peer)
        }
    }
}
