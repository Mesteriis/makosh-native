import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramMessageDeliveryMappingTests: XCTestCase {
    private func user(_ id: Int64, bot: Bool = false, support: Bool = false) -> TelegramUser {
        TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id)),
            accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [],
            botInfo: bot ? BotUserInfo(flags: [], inlinePlaceholder: nil) : nil, restrictionInfo: nil,
            flags: support ? [.isSupport] : [], emojiStatus: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            subscriberCount: nil, verificationIconFileId: nil)
    }
    private func channel(broadcast: Bool) -> TelegramChannel {
        TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(42)),
            accessHash: nil, title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
            participationStatus: .member, info: broadcast ? .broadcast(TelegramChannelBroadcastInfo(flags: [])) : .group(TelegramChannelGroupInfo(flags: [])),
            flags: [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil,
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil, subscriptionUntilDate: nil,
            verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
    }
    private func message(flags: MessageFlags = [], namespace: Int32 = Namespaces.Message.Cloud,
                         peer: Peer? = nil, author: Peer? = nil, attributes: [MessageAttribute] = []) -> Message {
        let target = peer ?? user(42)
        var peers = SimpleDictionary<PeerId, Peer>(); peers[target.id] = target
        return Message(stableId: 1, stableVersion: 1, id: MessageId(peerId: target.id, namespace: namespace, id: 7),
            globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 100,
            flags: flags, tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil,
            author: author ?? user(1), text: "Synthetic", attributes: attributes, media: [], peers: peers,
            associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
    }
    func testFlagPriorityAndUnknownNamespaces() {
        for (flags, expected): (MessageFlags, TelegramMessageDelivery) in [
            ([.Failed, .Sending, .Unsent], .failed), ([.Sending, .Unsent], .sending), ([.Unsent], .queued), ([], .sent)] {
            XCTAssertEqual(TelegramMessage(message(flags: flags), isRead: true).delivery, flags.isEmpty ? .read : expected)
        }
        for namespace in [Namespaces.Message.Local, Namespaces.Message.ScheduledCloud, Namespaces.Message.ScheduledLocal] {
            XCTAssertEqual(TelegramMessage(message(namespace: namespace)).delivery, .unknown)
            XCTAssertEqual(TelegramMessage(message(flags: [.Unsent], namespace: namespace)).delivery, .queued)
        }
    }
    func testHistoryReadContextDoesNotLeakIntoMessageOnlySearch() {
        let native = message()
        let entry = MessageHistoryEntry(message: native, isRead: true, location: nil, monthLocation: nil,
            attributes: MutableMessageHistoryEntryAttributes(authorIsContact: false))
        XCTAssertEqual(TelegramMessage(entry, accountID: user(1).id.toInt64()).delivery, .read)
        XCTAssertEqual(TelegramMessage(native, accountID: user(1).id.toInt64()).delivery, .sent)
        XCTAssertEqual(TelegramMessage(message(flags: [.Incoming], author: user(42)), isRead: true, accountID: user(1).id.toInt64()).delivery, .none)
    }
    func testBroadcastSuppressesChecksAndOwnSupergroupAuthorIsOutgoing() {
        let account = user(1)
        let broadcast = TelegramMessage(message(peer: channel(broadcast: true)), isRead: true, accountID: account.id.toInt64())
        XCTAssertFalse(broadcast.isOutgoing); XCTAssertEqual(broadcast.delivery, .none)
        for (flags, state): (MessageFlags, TelegramMessageDelivery) in [
            ([.Failed, .Sending, .Unsent], .failed), ([.Sending, .Unsent], .sending), ([.Unsent], .queued)] {
            XCTAssertEqual(TelegramMessage(message(flags: flags, peer: channel(broadcast: true)),
                isRead: true, accountID: account.id.toInt64()).delivery, state)
        }
        let group = TelegramMessage(message(flags: [.Incoming], peer: channel(broadcast: false), author: account),
            isRead: true, accountID: account.id.toInt64())
        XCTAssertTrue(group.isOutgoing); XCTAssertEqual(group.delivery, .read)
    }
    func testSavedBotSupportAndSourceConventionsAreDistinct() {
        let account = user(1)
        XCTAssertEqual(TelegramMessage(message(peer: account), accountID: account.id.toInt64()).delivery, .saved)
        XCTAssertEqual(TelegramMessage(message(peer: user(1, support: true)), accountID: account.id.toInt64()).delivery, .sent)
        XCTAssertEqual(TelegramMessage(message(peer: user(42, bot: true)), accountID: account.id.toInt64()).delivery, .sentToBot)
        XCTAssertEqual(TelegramMessage(message(peer: user(42, bot: true, support: true)), accountID: account.id.toInt64()).delivery, .sent)
        let source = SourceReferenceMessageAttribute(messageId: MessageId(peerId: user(99).id, namespace: 0, id: 3))
        XCTAssertEqual(TelegramMessage(message(peer: account, attributes: [source]), isRead: true, accountID: account.id.toInt64()).delivery, .sent)
    }
}
