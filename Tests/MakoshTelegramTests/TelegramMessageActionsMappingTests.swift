import XCTest
import Foundation
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramMessageActionsMappingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private var peerID: PeerId { PeerId(namespace: Namespaces.Peer.CloudUser,id: ._internalFromInt64Value(42)) }
    private func fixture(text: String = "original", version: UInt32 = 1, flags: MessageFlags = [],
                         timestamp: Int32 = 1_999_999, namespace: Int32 = Namespaces.Message.Cloud,
                         attributes: [MessageAttribute] = [], media: [Media] = [], threadID: Int64? = nil, peer: Peer? = nil) -> Message {
        let user = TelegramUser(id: peerID, accessHash: nil, firstName: "Synthetic", lastName: nil,
            username: nil, phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [],
            emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil,
            profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        var peers = SimpleDictionary<PeerId, Peer>(); peers[peer?.id ?? peerID] = peer ?? user
        return Message(stableId: 7,stableVersion: version,id: MessageId(peerId: peer?.id ?? peerID,namespace: namespace,id: 99),
            globallyUniqueId: nil,groupingKey: nil,groupInfo: nil,threadId: threadID,timestamp: timestamp,
            flags: flags,tags: [],globalTags: [],localTags: [],customTags: [],forwardInfo: nil,
            author: user,text: text,attributes: attributes,media: media,peers: peers,
            associatedMessages: SimpleDictionary(),associatedMessageIds: [],associatedMedia: [:],associatedThreadInfo: nil,associatedStories: [:])
    }
    func testTypedIdentityOwnershipAndConservativePlainTextPermissions() {
        let message = fixture(), account = peerID.toInt64()
        let mapped = telegramMessageActionSource(message,accountID: account,chatID: account,now: now)
        XCTAssertEqual(mapped.peerID,account); XCTAssertEqual(mapped.namespace,Namespaces.Message.Cloud)
        XCTAssertEqual(mapped.messageID,99); XCTAssertEqual(mapped.text,"original")
        XCTAssertTrue(mapped.canReply); XCTAssertTrue(mapped.canForward); XCTAssertTrue(mapped.canEdit)
        XCTAssertTrue(mapped.canDeleteLocally)
        let other = telegramMessageActionSource(message,accountID: account + 1,chatID: account,now: now)
        XCTAssertFalse(other.canEdit); XCTAssertFalse(other.canDeleteForEveryone)
    }
    func testVersionAndExactUTF8ChangesAlterFingerprint() {
        let original = telegramMessageActionMetadata(fixture(),now: now)
        XCTAssertEqual(original.fingerprint,telegramMessageActionMetadata(fixture(),now: now).fingerprint)
        XCTAssertNotEqual(original.fingerprint,telegramMessageActionMetadata(fixture(version: 2),now: now).fingerprint)
        XCTAssertNotEqual(telegramMessageActionMetadata(fixture(text: "é"),now: now).fingerprint,
                          telegramMessageActionMetadata(fixture(text: "e\u{301}"),now: now).fingerprint)
    }
    func testProtectedPendingAndUnsupportedNamespaceDoNotAdvertiseForwarding() {
        XCTAssertFalse(telegramMessageActionMetadata(fixture(flags: [.CopyProtected]),now: now).canForward)
        let pending = telegramMessageActionMetadata(fixture(flags: [.Unsent]),now: now)
        XCTAssertFalse(pending.canEdit); XCTAssertFalse(pending.canForward)
        let unsupported = telegramMessageActionMetadata(fixture(namespace: Int32.max),now: now)
        XCTAssertFalse(unsupported.canReply); XCTAssertFalse(unsupported.canForward); XCTAssertFalse(unsupported.canEdit)
    }
    func testOldOutgoingRemainsCandidateWhileIncomingAndEntitiesRequireOtherSupport() {
        XCTAssertTrue(telegramMessageActionMetadata(fixture(timestamp: 1),now: now).canEdit)
        XCTAssertFalse(telegramMessageActionMetadata(fixture(flags: [.Incoming]),now: now).canEdit)
        let entities = TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0..<3,type: .Bold)])
        XCTAssertFalse(telegramMessageActionMetadata(fixture(attributes: [entities]),now: now).canEdit)
    }
    func testPhotoCaptionLimitsEmptyEditAndThreadIdentity() {
        let photo = TelegramMediaImage(imageId: MediaId(namespace: 0,id: 7),representations: [],
            immediateThumbnailData: nil,reference: nil,partialReference: nil,flags: [])
        let text = telegramMessageActionSource(fixture(),accountID: peerID.toInt64(),chatID: peerID.toInt64(),now: now)
        let caption = telegramMessageActionSource(fixture(media: [photo],threadID: 123),accountID: peerID.toInt64(),chatID: peerID.toInt64(),now: now)
        XCTAssertEqual(text.editLimit,4096); XCTAssertEqual(caption.editLimit,1024)
        XCTAssertEqual(caption.threadID,123); XCTAssertTrue(caption.canReply)
        XCTAssertTrue(telegramMessageActionAllowed(.edit(String(repeating: "x",count: 4096)),source: text))
        XCTAssertFalse(telegramMessageActionAllowed(.edit(String(repeating: "x",count: 4097)),source: text))
        XCTAssertTrue(telegramMessageActionAllowed(.edit(String(repeating: "x",count: 1024)),source: caption))
        XCTAssertFalse(telegramMessageActionAllowed(.edit(String(repeating: "x",count: 1025)),source: caption))
        XCTAssertTrue(telegramMessageActionAllowed(.edit(""),source: caption))
        XCTAssertFalse(telegramMessageActionAllowed(.edit(""),source: text))
        XCTAssertNotEqual(caption.fingerprint,telegramMessageActionMetadata(fixture(media: [photo],threadID: 124),now: now).fingerprint)
    }
    func testExactUTF8NoChangeAndUTF16Limit() {
        let source = telegramMessageActionSource(fixture(text: "é"),accountID: peerID.toInt64(),chatID: peerID.toInt64(),now: now)
        XCTAssertFalse(telegramMessageActionAllowed(.edit("é"),source: source))
        XCTAssertTrue(telegramMessageActionAllowed(.edit("e\u{301}"),source: source))
        XCTAssertTrue(telegramMessageActionAllowed(.edit(String(repeating: "😀",count: 2048)),source: source))
        XCTAssertFalse(telegramMessageActionAllowed(.edit(String(repeating: "😀",count: 2049)),source: source))
    }
    func testProtectedGroupAndChannelAdminPermissionsComeFromRealPeers() {
        let groupID = PeerId(namespace: Namespaces.Peer.CloudGroup,id: ._internalFromInt64Value(8))
        let group = TelegramGroup(id: groupID,title: "Synthetic",photo: [],participantCount: 2,
            role: .member,membership: .Member,flags: [.copyProtectionEnabled],defaultBannedRights: nil,
            migrationReference: nil,creationDate: 0,version: 1)
        let groupSource = telegramMessageActionSource(fixture(peer: group),accountID: peerID.toInt64(),chatID: groupID.toInt64(),now: now)
        XCTAssertTrue(groupSource.canReply); XCTAssertTrue(groupSource.canDeleteLocally)
        XCTAssertFalse(groupSource.canForward)
        let channelID = PeerId(namespace: Namespaces.Peer.CloudChannel,id: ._internalFromInt64Value(9))
        let channel = TelegramChannel(id: channelID,accessHash: nil,title: "Synthetic",username: nil,
            photo: [],creationDate: 0,version: 1,participationStatus: .member,
            info: .broadcast(TelegramChannelBroadcastInfo(flags: [])),flags: [],restrictionInfo: nil,
            adminRights: TelegramChatAdminRights(rights: [.canEditMessages,.canDeleteMessages]),
            bannedRights: nil,defaultBannedRights: nil,usernames: [],storiesHidden: nil,nameColor: nil,
            backgroundEmojiId: nil,profileColor: nil,profileBackgroundEmojiId: nil,emojiStatus: nil,
            approximateBoostLevel: nil,subscriptionUntilDate: nil,verificationIconFileId: nil,
            sendPaidMessageStars: nil,linkedMonoforumId: nil)
        let admin = telegramMessageActionSource(fixture(flags: [.Incoming],peer: channel),accountID: 100,chatID: channelID.toInt64(),now: now)
        XCTAssertTrue(admin.canEdit); XCTAssertTrue(admin.canDeleteForEveryone)
        XCTAssertFalse(admin.canDeleteLocally)
    }

    func testBasicGroupIncomingDeletionRequiresCreatorOrDeleteAdminRights() {
        let groupID = PeerId(namespace: Namespaces.Peer.CloudGroup,id: ._internalFromInt64Value(18))
        let roles: [(TelegramGroupRole, Bool)] = [
            (.creator(rank: nil), true),
            (.admin(TelegramChatAdminRights(rights: [.canDeleteMessages]),rank: nil), true),
            (.admin(TelegramChatAdminRights(rights: [.canChangeInfo]),rank: nil), false),
            (.member, false)
        ]
        for (role, expected) in roles {
            let group = TelegramGroup(id: groupID,title: "Synthetic",photo: [],participantCount: 2,
                role: role,membership: .Member,flags: [],defaultBannedRights: nil,
                migrationReference: nil,creationDate: 0,version: 1)
            // Incoming author is the synthetic peer, distinct from the selected account.
            let source = telegramMessageActionSource(fixture(flags: [.Incoming],peer: group),
                accountID: peerID.toInt64() + 1,chatID: groupID.toInt64(),now: now)
            XCTAssertEqual(source.canDeleteForEveryone,expected)
            XCTAssertEqual(telegramMessageActionAllowed(.delete(forEveryone: true),source: source),expected)
            XCTAssertTrue(source.canDeleteLocally)
        }
    }

}
