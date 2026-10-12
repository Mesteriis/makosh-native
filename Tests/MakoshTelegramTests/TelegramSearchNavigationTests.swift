import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

private nonisolated func searchNavigationChannel(
    broadcast: Bool = false,
    flags: TelegramChannelFlags = []
) -> TelegramChannel {
    TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(43)),
        accessHash: .personal(101), title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
        participationStatus: .member,
        info: broadcast ? .broadcast(.init(flags: [])) : .group(.init(flags: [])),
        flags: flags, restrictionInfo: nil, adminRights: nil, bannedRights: nil,
        defaultBannedRights: nil, usernames: [], storiesHidden: nil, nameColor: nil,
        backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, emojiStatus: nil,
        approximateBoostLevel: nil, subscriptionUntilDate: nil, verificationIconFileId: nil,
        sendPaidMessageStars: nil, linkedMonoforumId: nil)
}

private nonisolated func searchNavigationSavedUser() -> TelegramUser {
    TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(42)),
        accessHash: .personal(100), firstName: "Synthetic", lastName: nil, username: nil,
        phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil,
        usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
        profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
}

final class TelegramSearchNavigationTests: XCTestCase {
    func testOrdinaryBroadcastDefaultAndReplyThreadsOpenAllMessages() {
        let peer = searchNavigationChannel(broadcast: true)
        // Native channel ingestion assigns thread 1 even when this is not a forum.
        for thread in [Int64(1), 7] {
            XCTAssertNil(telegramSearchNavigationThread(peer: peer, threadID: thread))
        }
        XCTAssertNil(telegramSearchNavigationThread(peer: peer, threadID: nil))
    }

    func testOrdinarySupergroupThreadsOpenAllMessages() {
        let peer = searchNavigationChannel()
        for thread in [Int64(1), 7] {
            XCTAssertNil(telegramSearchNavigationThread(peer: peer, threadID: thread))
        }
    }

    func testSavedMessagesPackedPeerThreadsNeverBecomeForumTopics() {
        let peer = searchNavigationSavedUser()
        let subPeers = [
            PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(7)),
            PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(8))
        ]
        for subPeer in subPeers {
            XCTAssertNil(telegramSearchNavigationThread(peer: peer, threadID: subPeer.toInt64()))
        }
    }

    func testMonoforumAndCombinedForumFlagsNeverTreatSubPeersAsTopics() {
        for flags: TelegramChannelFlags in [[.isMonoforum], [.isForum, .isMonoforum]] {
            let peer = searchNavigationChannel(flags: flags)
            for thread in [Int64(1), 7, PeerId(namespace: Namespaces.Peer.CloudGroup,
                id: ._internalFromInt64Value(8)).toInt64()] {
                XCTAssertNil(telegramSearchNavigationThread(peer: peer, threadID: thread))
            }
        }
    }

    func testMissingPeerCannotEstablishForumThreadAuthority() {
        for thread in [Int64(1), 7, Int64(Int32.max)] {
            XCTAssertNil(telegramSearchNavigationThread(peer: nil, threadID: thread))
        }
    }

    func testActualForumPreservesOnlyExactPositiveInt32Topics() {
        let peer = searchNavigationChannel(flags: [.isForum])
        for thread in [Int64(1), 7, Int64(Int32.max)] {
            XCTAssertEqual(telegramSearchNavigationThread(peer: peer, threadID: thread), thread)
        }
        for thread in [Int64(0), -1, Int64(Int32.min), Int64(Int32.max) + 1, Int64.max, Int64.min] {
            XCTAssertNil(telegramSearchNavigationThread(peer: peer, threadID: thread))
        }
        XCTAssertNil(telegramSearchNavigationThread(peer: peer, threadID: nil))
    }
}
