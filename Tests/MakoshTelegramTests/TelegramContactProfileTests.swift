import XCTest
import Foundation
import Postbox
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramContactProfileTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 2_000_000)

    private func user(first: String? = "Synthetic", last: String? = "Person",
                      username: String? = "synthetic_user", phone: String? = "10000000000",
                      bot: Bool = false, secretNamespace: Bool = false) -> TelegramUser {
        TelegramUser(id: PeerId(namespace: secretNamespace ? Namespaces.Peer.SecretChat : Namespaces.Peer.CloudUser,
            id: ._internalFromInt64Value(42)), accessHash: nil, firstName: first, lastName: last,
            username: username, phone: phone, photo: [],
            botInfo: bot ? BotUserInfo(flags: [], inlinePlaceholder: nil) : nil,
            restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
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

    func testGroupChannelAndWrongUserNamespaceAreRejected() {
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
        XCTAssertNil(telegramContactProfile(peer: group, accountID: 1, observedAt: observed))
        XCTAssertNil(telegramContactProfile(peer: channel, accountID: 1, observedAt: observed))
        XCTAssertNil(telegramContactProfile(peer: user(secretNamespace: true), accountID: 1, observedAt: observed))
    }
}
