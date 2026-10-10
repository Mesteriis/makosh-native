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
    func testOldOutgoingRemainsCandidateAndRichEntitiesUseFormattedEdit() {
        XCTAssertTrue(telegramMessageActionMetadata(fixture(timestamp: 1),now: now).canEdit)
        XCTAssertFalse(telegramMessageActionMetadata(fixture(flags: [.Incoming]),now: now).canEdit)
        let entities = TextEntitiesMessageAttribute(entities: [MessageTextEntity(range: 0..<3,type: .Bold)])
        XCTAssertTrue(telegramMessageActionMetadata(fixture(attributes: [entities]),now: now).canEdit)
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

    func testEveryNativeEntityRoundTripsWithoutDroppingUnsupportedKinds() throws {
        let kinds: [MessageTextEntityType] = [.Unknown,.Mention,.Hashtag,.BotCommand,.Url,.Email,
            .Bold,.Italic,.Code,.Pre(language: "swift"),.Pre(language: nil),.TextUrl(url: "https://example.invalid/é"),
            .TextMention(peerId: peerID),.PhoneNumber,.Strikethrough,.BlockQuote(isCollapsed: true),
            .Underline,.BankCard,.Spoiler,.CustomEmoji(stickerPack: .id(id: 10,accessHash: 11),fileId: 12),.Custom(type: 13)]
        for kind in kinds {
            let native = MessageTextEntity(range: 0..<2,type: kind)
            let formatted = try telegramFormattedText(text: "😀",entities: [native])
            XCTAssertEqual(formatted.engineEntities(),[native])
            XCTAssertEqual(try JSONDecoder().decode(TelegramFormattedText.self,from: JSONEncoder().encode(formatted)),formatted)
        }
        let packs: [StickerPackReference] = [.id(id: 1,accessHash: 2),.name("é"),.animatedEmoji,.dice("🎲"),
            .animatedEmojiAnimations,.premiumGifts,.emojiGenericAnimations,.iconStatusEmoji,
            .iconTopicEmoji,.iconChannelStatusEmoji,.tonGifts]
        for pack in packs {
            let native = MessageTextEntity(range: 0..<2,type: .CustomEmoji(stickerPack: pack,fileId: 99))
            XCTAssertEqual(try telegramFormattedText(text: "😀",entities: [native]).engineEntities(),[native])
        }
        let unknown = try telegramFormattedText(text: "x",entities: [.init(range: 0..<1,type: .Unknown)])
        XCTAssertEqual(unknown.entities.first?.kind,.unknown); XCTAssertFalse(unknown.isEditable)
        let source = telegramMessageActionSource(fixture(text: "x",attributes: [TextEntitiesMessageAttribute(entities: unknown.engineEntities())]),
            accountID: peerID.toInt64(),chatID: peerID.toInt64(),now: now)
        XCTAssertFalse(source.canEdit)
    }

    func testFormatOnlyChangesAreMutationsButPlainEditCannotDropFormatting() throws {
        let native = MessageTextEntity(range: 0..<3,type: .Bold)
        let source = telegramMessageActionSource(fixture(text: "abc",attributes: [TextEntitiesMessageAttribute(entities: [native])]),
            accountID: peerID.toInt64(),chatID: peerID.toInt64(),now: now)
        let original = try XCTUnwrap(source.metadata.formattedText)
        XCTAssertFalse(telegramMessageActionAllowed(.editFormatted(original),source: source))
        XCTAssertFalse(telegramMessageActionAllowed(.edit("changed"),source: source))
        let italic = try TelegramFormattedText(text: "abc",entities: [.init(offset: 0,length: 3,kind: .italic)])
        XCTAssertTrue(telegramMessageActionAllowed(.editFormatted(italic),source: source))
        XCTAssertNotEqual(original,italic)
    }

    func testOutgoingChannelAndSendAsAuthorsUseSelectedAccountOutFlagAndPostingRights() {
        let id = PeerId(namespace: Namespaces.Peer.CloudChannel,id: ._internalFromInt64Value(999))
        let channel = TelegramChannel(id: id,accessHash: nil,title: "Synthetic",username: nil,
            photo: [],creationDate: 0,version: 1,participationStatus: .member,
            info: .broadcast(TelegramChannelBroadcastInfo(flags: [])),flags: [],restrictionInfo: nil,
            adminRights: TelegramChatAdminRights(rights: [.canPostMessages]),bannedRights: nil,
            defaultBannedRights: nil,usernames: [],storiesHidden: nil,nameColor: nil,backgroundEmojiId: nil,
            profileColor: nil,profileBackgroundEmojiId: nil,emojiStatus: nil,approximateBoostLevel: nil,
            subscriptionUntilDate: nil,verificationIconFileId: nil,sendPaidMessageStars: nil,linkedMonoforumId: nil)
        let account: Int64 = 123456
        // Native outgoing posts may be authored by channel or a separate send-as peer.
        for author: Peer? in [channel,nil] {
            let outgoing = telegramMessageActionSource(fixture(peer: channel,author: author),accountID: account,chatID: id.toInt64(),now: now)
            XCTAssertNotEqual(outgoing.metadata.authorID,account)
            XCTAssertTrue(outgoing.canEdit); XCTAssertTrue(outgoing.canDeleteForEveryone)
            XCTAssertFalse(outgoing.canDeleteLocally)
        }
        let incoming = telegramMessageActionSource(fixture(flags: [.Incoming],peer: channel,author: channel),
            accountID: account,chatID: id.toInt64(),now: now)
        XCTAssertFalse(incoming.canEdit); XCTAssertFalse(incoming.canDeleteForEveryone)
    }

    @MainActor func testReadingMappingPreservesSourceAndMasksPreviewAndRejectsInvalidEntities() throws {
        let native = fixture(text: "😀 hidden", attributes: [TextEntitiesMessageAttribute(entities: [
            MessageTextEntity(range: 0..<2, type: .Bold), MessageTextEntity(range: 3..<9, type: .Spoiler)])])
        let mapped = TelegramMessage(native)
        XCTAssertEqual(mapped.text, "😀 hidden")
        XCTAssertEqual(try XCTUnwrap(mapped.formattedTextForDisplay).entities.count, 2)
        XCTAssertEqual(telegramMessagePreview(native), "😀 ██████")
        let malformed = fixture(text: "😀 hidden", attributes: [TextEntitiesMessageAttribute(entities: [
            MessageTextEntity(range: 1..<2, type: .Spoiler)])])
        XCTAssertNil(TelegramMessage(malformed).formattedTextForDisplay)
        XCTAssertEqual(telegramMessagePreview(malformed), "Форматирование сообщения недоступно")
    }

    func testReadingMappingDoesNotSubstituteUnicodeEquivalentOrMissingFormattedSource() throws {
        var message = TelegramMessage(id: "fixture", date: now, text: "é", author: "Synthetic", isOutgoing: false, delivery: "")
        XCTAssertEqual(message.formattedTextForDisplay?.text, "é")
        message.actionMetadata = TelegramMessageActionMetadata(peerID: 1, namespace: 0, messageID: 1,
            fingerprint: "fixture", text: "é", authorID: 1, canReply: false, canEdit: false,
            canForward: false, canDeleteLocally: false, canDeleteForEveryone: false,
            formattedText: try TelegramFormattedText(text: "e\u{301}"))
        XCTAssertNil(message.formattedTextForDisplay)
    }

}
