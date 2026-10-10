import XCTest
import Foundation
import Postbox
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramContactProfileTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 2_000_000)

    private func user(first: String? = "Synthetic", last: String? = "Person",
                      username: String? = "synthetic_user", phone: String? = "10000000000",
                      bot: Bool = false, flags: UserInfoFlags = [], secretNamespace: Bool = false) -> TelegramUser {
        TelegramUser(id: PeerId(namespace: secretNamespace ? Namespaces.Peer.SecretChat : Namespaces.Peer.CloudUser,
            id: ._internalFromInt64Value(42)), accessHash: nil, firstName: first, lastName: last,
            username: username, phone: phone, photo: [],
            botInfo: bot ? BotUserInfo(flags: [], inlinePlaceholder: nil) : nil,
            restrictionInfo: nil, flags: flags, emojiStatus: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            subscriberCount: nil, verificationIconFileId: nil)
    }

    func testNativeFieldsAndProvenanceRemainAccountScoped() throws {
        let peer = user(bot: true)
        let first = try XCTUnwrap(telegramContactProfile(peer: peer, accountID: 101, observedAt: observed))
        let second = try XCTUnwrap(telegramContactProfile(peer: peer, accountID: 202, observedAt: observed))
        XCTAssertEqual(first.peerID, peer.id.toInt64())
        XCTAssertEqual(first.accountID, 101); XCTAssertEqual(second.accountID, 202)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.displayName, "Synthetic Person")
        XCTAssertEqual(first.username, peer.username); XCTAssertEqual(first.phone, peer.phone)
        XCTAssertTrue(first.isBot); XCTAssertEqual(first.observedAt, observed)
        XCTAssertEqual(first.dossierIdentity.accountID, "101")
        XCTAssertEqual(first.dossierIdentity.externalID, String(peer.id.toInt64()))
        XCTAssertEqual(first.dossierImport.phones, ["10000000000"])
        XCTAssertTrue(first.dossierImport.notes.isEmpty)
        XCTAssertEqual(first, TelegramContactProfile(accountID: 101, peerID: peer.id.toInt64(),
            displayName: "Synthetic Person", username: "synthetic_user", phone: "10000000000",
            isBot: true, observedAt: observed))
    }

    func testOptionalAndEmptyFieldsAreNotInventedOrNormalized() throws {
        let empty = try XCTUnwrap(telegramContactProfile(peer: user(first: nil, last: "", username: nil, phone: nil),
            accountID: 1, observedAt: observed))
        XCTAssertEqual(empty.displayName, ""); XCTAssertNil(empty.username); XCTAssertNil(empty.phone)
        XCTAssertFalse(empty.isBot)
        XCTAssertTrue(empty.dossierImport.phones.isEmpty)
        let raw = try XCTUnwrap(telegramContactProfile(peer: user(first: "", last: "e\u{301}", username: "", phone: ""),
            accountID: 1, observedAt: observed))
        XCTAssertTrue(raw.displayName.utf8.elementsEqual("e\u{301}".utf8))
        XCTAssertEqual(raw.username, ""); XCTAssertEqual(raw.phone, "")
    }

    func testGroupChannelAndWrongUserNamespaceAreRejected() throws {
        let group = TelegramGroup(id: PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(42)),
            title: "Synthetic", photo: [], participantCount: 2, role: .member, membership: .Member,
            flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 1)
        let channel = TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(42)),
            accessHash: nil, title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
            participationStatus: .member, info: .broadcast(TelegramChannelBroadcastInfo(flags: [])),
            flags: [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil,
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil,
            subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
        let basic = try XCTUnwrap(telegramContactProfile(peer: group, accountID: 1, observedAt: observed,
            cachedData: CachedGroupData().withUpdatedAbout("Group about")))
        XCTAssertEqual(basic.kind, .group); XCTAssertEqual(basic.memberCount, 2)
        XCTAssertEqual(basic.about, "Group about"); XCTAssertFalse(basic.isPerson)
        XCTAssertNil(basic.phone); XCTAssertNil(basic.username)
        let broadcast = try XCTUnwrap(telegramContactProfile(peer: channel, accountID: 1, observedAt: observed,
            cachedData: CachedChannelData().withUpdatedAbout("Channel about").withUpdatedParticipantsSummary(
                CachedChannelParticipantsSummary(memberCount: 37, adminCount: nil, bannedCount: nil, kickedCount: nil))))
        XCTAssertEqual(broadcast.kind, .channel); XCTAssertEqual(broadcast.memberCount, 37)
        XCTAssertEqual(broadcast.about, "Channel about")
        XCTAssertEqual(telegramContactProfile(peer: channel, accountID: 1, observedAt: observed,
            cachedData: CachedChannelData().withUpdatedParticipantsSummary(
                CachedChannelParticipantsSummary(memberCount: 0, adminCount: nil, bannedCount: nil, kickedCount: nil)))?.memberCount, 0)
        XCTAssertNil(telegramContactProfile(peer: channel, accountID: 1, observedAt: observed)?.memberCount)
        let supergroup = channel.withUpdatedInfo(.group(TelegramChannelGroupInfo(flags: [])))
        let discussion = try XCTUnwrap(telegramContactProfile(peer: supergroup, accountID: 2, observedAt: observed,
            cachedData: CachedChannelData().withUpdatedParticipantsSummary(
                CachedChannelParticipantsSummary(memberCount: -1, adminCount: nil, bannedCount: nil, kickedCount: nil))))
        XCTAssertEqual(discussion.kind, .supergroup); XCTAssertNil(discussion.memberCount)
        XCTAssertEqual(discussion.peerID, supergroup.id.toInt64()); XCTAssertEqual(discussion.accountID, 2)
        for flags: TelegramChannelFlags in [.isScam, .isFake] {
            let flagged = try XCTUnwrap(telegramContactProfile(peer: channel.withUpdatedFlags(flags),
                accountID: 1, observedAt: observed, cachedData: CachedChannelData().withUpdatedAbout("Hidden")))
            XCTAssertNil(flagged.about)
            XCTAssertEqual(flagged.isScam, flags.contains(.isScam))
            XCTAssertEqual(flagged.isFake, flags.contains(.isFake))
        }
        XCTAssertNil(telegramContactProfile(peer: user(secretNamespace: true), accountID: 1, observedAt: observed))
    }

    func testUserAboutAndScamFakeSuppression() throws {
        let cached = CachedUserData().withUpdatedAbout("Synthetic biography")
        let normal = try XCTUnwrap(telegramContactProfile(peer: user(), accountID: 1, observedAt: observed, cachedData: cached))
        XCTAssertTrue(normal.isPerson); XCTAssertEqual(normal.about, "Synthetic biography")
        XCTAssertNil(normal.memberCount)
        for flags: UserInfoFlags in [.isScam, .isFake] {
            let flagged = try XCTUnwrap(telegramContactProfile(peer: user(flags: flags), accountID: 1,
                observedAt: observed, cachedData: cached))
            XCTAssertNil(flagged.about)
            XCTAssertEqual(flagged.isScam, flags.contains(.isScam))
            XCTAssertEqual(flagged.isFake, flags.contains(.isFake))
        }
    }
}
