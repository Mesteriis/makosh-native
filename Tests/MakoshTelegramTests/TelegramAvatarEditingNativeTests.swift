import XCTest
import TelegramCore
import TelegramApi
import Postbox
@testable import MakoshTelegram

final class TelegramAvatarEditingNativeTests: XCTestCase {
    private let account: Int64 = 101
    func testAccountAndFallbackUploadAndRemovalUseDifferentFlags() throws {
        let file = Api.InputFile.inputFile(id: 7, parts: 1, name: "file.jpg", md5Checksum: "")
        let own = TelegramAvatarTarget(accountID: account, peerID: account, kind: .main)
        let fallback = TelegramAvatarTarget(accountID: account, peerID: account, kind: .fallback)
        let upload = try XCTUnwrap(telegramAvatarUserRPC(target: own, file: file))
        XCTAssertEqual(upload.0.name, "photos.uploadProfilePhoto")
        XCTAssertEqual(String(describing: upload.0.parameters[0].1), "1")
        let publicUpload = try XCTUnwrap(telegramAvatarUserRPC(target: fallback, file: file))
        XCTAssertEqual(String(describing: publicUpload.0.parameters[0].1), "9")
        let removal = try XCTUnwrap(telegramAvatarUserRPC(target: fallback, file: nil))
        XCTAssertEqual(removal.0.name, "photos.updateProfilePhoto")
        XCTAssertEqual(String(describing: removal.0.parameters[0].1), "1")
        XCTAssertNil(telegramAvatarUserRPC(target: .init(accountID: account, peerID: 102, kind: .main), file: file))
    }
    func testFreshGroupRightsAreRequiredAndFallbackCannotTargetGroup() {
        let peerID = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(10))
        let target = TelegramAvatarTarget(accountID: account, peerID: peerID.toInt64(), kind: .main)
        func group(_ bans: TelegramChatBannedRights?, _ membership: TelegramGroupMembership = .Member) -> TelegramGroup {
            .init(id: peerID, title: "Synthetic group", photo: [], participantCount: 2, role: .member, membership: membership,
                flags: [], defaultBannedRights: bans, migrationReference: nil, creationDate: 0, version: 1)
        }
        XCTAssertEqual(telegramAvatarSnapshot(peer: group(nil), image: nil, target: target)?.canEdit, true)
        XCTAssertEqual(telegramAvatarSnapshot(peer: group(.init(flags: [.banChangeInfo], untilDate: Int32.max)), image: nil, target: target)?.canEdit, false)
        XCTAssertNil(telegramAvatarSnapshot(peer: group(nil, .Left), image: nil, target: target))
        XCTAssertNil(telegramAvatarSnapshot(peer: group(nil), image: nil, target: .init(accountID: account, peerID: target.peerID, kind: .fallback)))
    }
    func testFreshBasisRefusesChangedPhotoRightsAndDestination() {
        let target = TelegramAvatarTarget(accountID: account, peerID: account, kind: .main)
        let basis = TelegramAvatarSnapshot(target: target, title: "Own", photoID: 7, canEdit: true)
        XCTAssertTrue(telegramAdmitAvatarChange(basis: basis, fresh: basis, removing: true))
        XCTAssertFalse(telegramAdmitAvatarChange(basis: basis, fresh: .init(target: target, title: "Own", photoID: 8, canEdit: true), removing: true))
        XCTAssertFalse(telegramAdmitAvatarChange(basis: basis, fresh: .init(target: target, title: "Own", photoID: 7, canEdit: false), removing: false))
        XCTAssertFalse(telegramAdmitAvatarChange(basis: basis, fresh: .init(target: .init(accountID: 102, peerID: 102, kind: .main), title: "Own", photoID: 7, canEdit: true), removing: false))
    }
    func testMissingGroupAcknowledgementNeverConfirmsPhotoChange() {
        let id = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(10))
        XCTAssertNil(makoshAvatarUpdatedChat(.updatesTooLong, peerId: id))
        XCTAssertNil(makoshAvatarUpdatedChat(.updates(updates: [], users: [], chats: [], date: 0, seq: 0), peerId: id))
    }
    func testMinChannelCannotAcknowledgeAFullPhotoChange() {
        let id = PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(10))
        let min = Api.Chat.channel(flags: (1 << 12), flags2: 0, id: 10, accessHash: 77, title: "Synthetic min", username: nil,
            photo: .chatPhotoEmpty, date: 1, restrictionReason: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil,
            participantsCount: nil, usernames: nil, storiesMaxId: nil, color: nil, profileColor: nil, emojiStatus: nil,
            level: nil, subscriptionUntilDate: nil, botVerificationIcon: nil, sendPaidMessagesStars: nil, linkedMonoforumId: nil)
        XCTAssertNil(makoshAvatarUpdatedChat(.updates(updates: [], users: [], chats: [min], date: 1, seq: 1), peerId: id))
    }
    func testFullOwnProfileSeparatesFallbackAndRejectsMinWrongOrIncompleteIdentity() throws {
        let id = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(account))
        func photo(_ id: Int64) -> Api.Photo {
            .photo(flags: 0, id: id, accessHash: 77, fileReference: Buffer(data: Data([1])), date: 1,
                sizes: [.photoSize(type: "x", w: 640, h: 640, size: 100)], videoSizes: nil, dcId: 2)
        }
        func user(_ raw: Int64 = 101, min: Bool = false) -> Api.User {
            .user(flags: 2 | (1 << 5) | (min ? 1 << 20 : 0), flags2: 0, id: raw, accessHash: nil, firstName: "Synthetic own", lastName: nil,
                username: nil, phone: nil, photo: .userProfilePhoto(flags: 0, photoId: 7, strippedThumb: nil, dcId: 2), status: nil,
                botInfoVersion: nil, restrictionReason: nil, botInlinePlaceholder: nil, langCode: nil, emojiStatus: nil,
                usernames: nil, storiesMaxId: nil, color: nil, profileColor: nil, botActiveUsers: nil, botVerificationIcon: nil, sendPaidMessagesStars: nil)
        }
        let full = Api.UserFull.userFull(flags: 0, flags2: 0, id: account, about: nil,
            settings: .peerSettings(flags: 0, geoDistance: nil, requestChatTitle: nil, requestChatDate: nil, businessBotId: nil,
                businessBotManageUrl: nil, chargePaidMessageStars: nil, registrationMonth: nil, phoneCountry: nil, nameChangeDate: nil, photoChangeDate: nil),
            personalPhoto: nil, profilePhoto: photo(7), fallbackPhoto: photo(8),
            notifySettings: .peerNotifySettings(flags: 0, showPreviews: nil, silent: nil, muteUntil: nil, iosSound: nil, androidSound: nil,
                otherSound: nil, storiesMuted: nil, storiesHideSender: nil, storiesIosSound: nil, storiesAndroidSound: nil, storiesOtherSound: nil),
            botInfo: nil, pinnedMsgId: nil, commonChatsCount: 0, folderId: nil, ttlPeriod: nil, themeEmoticon: nil, privateForwardName: nil,
            botGroupAdminRights: nil, botBroadcastAdminRights: nil, wallpaper: nil, stories: nil, businessWorkHours: nil,
            businessLocation: nil, businessGreetingMessage: nil, businessAwayMessage: nil, businessIntro: nil, birthday: nil,
            personalChannelId: nil, personalChannelMessage: nil, stargiftsCount: nil, starrefProgram: nil, botVerification: nil,
            sendPaidMessagesStars: nil, disallowedGifts: nil, starsRating: nil)
        let response = Api.users.UserFull.userFull(fullUser: full, chats: [], users: [user()])
        XCTAssertEqual(makoshAvatarUserPhotoResult(response, accountPeerId: id, fallback: false)?.image?.imageId.id, 7)
        XCTAssertEqual(makoshAvatarUserPhotoResult(response, accountPeerId: id, fallback: true)?.image?.imageId.id, 8)
        XCTAssertNil(makoshAvatarUserPhotoResult(.userFull(fullUser: full, chats: [], users: [user(min: true)]), accountPeerId: id, fallback: true))
        XCTAssertNil(makoshAvatarUserPhotoResult(.userFull(fullUser: full, chats: [], users: [user(102)]), accountPeerId: id, fallback: false))
        XCTAssertNil(makoshAvatarUserPhotoResult(.userFull(fullUser: full, chats: [], users: []), accountPeerId: id, fallback: false))
        XCTAssertNil(makoshAvatarUserPhotoResult(.userFull(fullUser: full, chats: [], users: [user(), user()]), accountPeerId: id, fallback: false))
    }
    func testNativeFullGroupReplyRejectsWrongPeerAndPartialPhotoBasis() throws {
        let id = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(10))
        let chat = Api.Chat.chat(flags: 1, id: 10, title: "Synthetic group", photo: .chatPhotoEmpty,
            participantsCount: 2, date: 1, version: 1, migratedTo: nil, adminRights: nil, defaultBannedRights: nil)
        let full = Api.ChatFull.chatFull(flags: 0, id: 10, about: "", participants: .chatParticipantsForbidden(flags: 0, chatId: 10, selfParticipant: nil),
            chatPhoto: nil, notifySettings: .peerNotifySettings(flags: 0, showPreviews: nil, silent: nil, muteUntil: nil, iosSound: nil, androidSound: nil, otherSound: nil, storiesMuted: nil, storiesHideSender: nil, storiesIosSound: nil, storiesAndroidSound: nil, storiesOtherSound: nil),
            exportedInvite: nil, botInfo: nil, pinnedMsgId: nil, folderId: nil, call: nil, ttlPeriod: nil,
            groupcallDefaultJoinAs: nil, themeEmoticon: nil, requestsPending: nil, recentRequesters: nil, availableReactions: nil, reactionsLimit: nil)
        let response = Api.messages.ChatFull.chatFull(fullChat: full, chats: [chat], users: [])
        XCTAssertNotNil(makoshAvatarChatPhotoResult(response, peerId: id))
        XCTAssertNil(makoshAvatarChatPhotoResult(response, peerId: PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(11))))
        XCTAssertNil(makoshAvatarChatPhotoResult(.chatFull(fullChat: full, chats: [chat, chat], users: []), peerId: id))
    }
}
