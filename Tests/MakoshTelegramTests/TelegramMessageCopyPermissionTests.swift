import XCTest
import Foundation
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramMessageCopyPermissionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private var peerID: PeerId { PeerId(namespace: Namespaces.Peer.CloudUser,id: ._internalFromInt64Value(42)) }
    private func fixture(text: String = "original", version: UInt32 = 1, flags: MessageFlags = [],
                         timestamp: Int32 = 1_999_999, namespace: Int32 = Namespaces.Message.Cloud,
                         attributes: [MessageAttribute] = [], media: [Media] = [], threadID: Int64? = nil, peer: Peer? = nil, author: Peer? = nil) -> Message {
        let user = TelegramUser(id: peerID, accessHash: nil, firstName: "Synthetic", lastName: nil,
            username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
            emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
            profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        var peers = SimpleDictionary<PeerId, Peer>(); peers[peer?.id ?? peerID] = peer ?? user
        return Message(stableId: 7,stableVersion: version,id: MessageId(peerId: peer?.id ?? peerID,namespace: namespace,id: 99),
            globallyUniqueId: nil,groupingKey: nil,groupInfo: nil,threadId: threadID,timestamp: timestamp,
            flags: flags,tags: [],globalTags: [],localTags: [],customTags: [],forwardInfo: nil,
            author: author ?? user,text: text,attributes: attributes,media: media,peers: peers,
            associatedMessages: SimpleDictionary(),associatedMessageIds: [],associatedMedia: [:],associatedThreadInfo: nil,associatedStories: [:])
    }

    func testUserAndMessageProtectionMapCopyIndependently() {
        let plain = telegramMessageActionMetadata(fixture(),now: now)
        XCTAssertTrue(plain.canCopy)
        XCTAssertTrue(TelegramMessageActionSource(metadata: plain,accountID: 1,chatID: plain.peerID).canCopy)
        XCTAssertFalse(telegramMessageActionMetadata(fixture(flags: [.CopyProtected]),now: now).canCopy)
        let explicit = TelegramMessageActionMetadata(peerID: 1,namespace: 0,messageID: 2,fingerprint: "v",
            text: "Synthetic",authorID: 1,canReply: false,canEdit: false,canForward: false,
            canDeleteLocally: false,canDeleteForEveryone: false,canCopy: true)
        XCTAssertTrue(explicit.canCopy); XCTAssertFalse(explicit.canForward)
        let legacy = TelegramMessageActionSource(accountID: 1,chatID: 1,peerID: 1,namespace: 0,
            messageID: 2,fingerprint: "v",text: "Synthetic",canReply: true,canEdit: true,
            canForward: true,canDeleteLocally: true,canDeleteForEveryone: true)
        XCTAssertFalse(legacy.canCopy) // Omitted capability fails closed, never inferred from forwarding.
    }
    func testGroupAndChannelProtectionDenyCopyEvenWithoutMessageFlag() {
        let groupID = PeerId(namespace: Namespaces.Peer.CloudGroup,id: ._internalFromInt64Value(8))
        let channelID = PeerId(namespace: Namespaces.Peer.CloudChannel,id: ._internalFromInt64Value(9))
        for protected in [false,true] {
            let group = TelegramGroup(id: groupID,title: "Synthetic",photo: [],participantCount: 2,
                role: .member,membership: .Member,flags: protected ? [.copyProtectionEnabled] : [],
                defaultBannedRights: nil,migrationReference: nil,creationDate: 0,version: 1)
            XCTAssertEqual(telegramMessageActionMetadata(fixture(peer: group),now: now).canCopy,!protected)
            let channel = TelegramChannel(id: channelID,accessHash: nil,title: "Synthetic",username: nil,
                photo: [],creationDate: 0,version: 1,participationStatus: .member,
                info: .broadcast(TelegramChannelBroadcastInfo(flags: [])),flags: protected ? [.copyProtectionEnabled] : [],restrictionInfo: nil,
                adminRights: nil,bannedRights: nil,defaultBannedRights: nil,usernames: [],storiesHidden: nil,nameColor: nil,
                backgroundEmojiId: nil,profileColor: nil,profileBackgroundEmojiId: nil,emojiStatus: nil,
                approximateBoostLevel: nil,subscriptionUntilDate: nil,verificationIconFileId: nil,
                sendPaidMessageStars: nil,linkedMonoforumId: nil)
            XCTAssertEqual(telegramMessageActionMetadata(fixture(peer: channel),now: now).canCopy,!protected)
        }
    }
}
