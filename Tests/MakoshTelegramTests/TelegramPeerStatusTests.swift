import XCTest
import Foundation
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramPeerStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func status(_ presence: TelegramPeerStatus.Presence? = nil, activity: Int32 = 0,
                        offset: Double = 0, kind: TelegramContactProfile.Kind = .person, count: Int? = nil,
                        selfPeer: Bool = false, support: Bool = false, service: Bool = false) -> TelegramPeerStatus {
        TelegramPeerStatus(accountID: 1, peerID: 2, kind: kind, presence: presence, lastActivity: activity,
            memberCount: count, isSelf: selfPeer, isSupport: support, isService: service, serverTimeOffset: offset)
    }
    func testServerOffsetExpiryAndExactBoundary() {
        let value = status(.present(until: 1100), offset: 90)
        XCTAssertTrue(value.presentation(now: now).isOnline)
        XCTAssertEqual(value.presentation(now: now).nextRefresh, now.addingTimeInterval(10))
        let expired = value.presentation(now: now.addingTimeInterval(10))
        XCTAssertFalse(expired.isOnline); XCTAssertEqual(expired.text, "Был(а) только что")
        XCTAssertEqual(expired.nextRefresh, now.addingTimeInterval(69))
        XCTAssertFalse(value.presentation(now: now.addingTimeInterval(11)).isOnline)
        XCTAssertTrue(status(.present(until: 1001), offset: -50).presentation(now: now).isOnline)
    }
    func testRelativeRefreshBoundariesNeverSpinOrInventOnline() throws {
        let value = status(.present(until: 1000))
        let justNow = value.presentation(now: Date(timeIntervalSince1970: 1058))
        XCTAssertEqual(justNow.nextRefresh, Date(timeIntervalSince1970: 1059))
        let minute = value.presentation(now: Date(timeIntervalSince1970: 1059))
        XCTAssertEqual(minute.text, "Был(а) 1 мин. назад")
        XCTAssertGreaterThan(try XCTUnwrap(minute.nextRefresh), Date(timeIntervalSince1970: 1059))
        let old = value.presentation(now: Date(timeIntervalSince1970: 5000))
        XCTAssertFalse(old.isOnline); XCTAssertNil(old.nextRefresh)
        XCTAssertFalse(status(.present(until: Int32.max), offset: .infinity).presentation(now: now).isOnline)
    }
    func testPrivacyBucketsRemainApproximateAndActivityExpires() {
        for hidden in [false, true] {
            for presence: TelegramPeerStatus.Presence in [.recently(isHidden: hidden), .lastWeek(isHidden: hidden), .lastMonth(isHidden: hidden)] {
                let value = status(presence)
                XCTAssertEqual(value.presence, presence)
                let presentation = value.presentation(now: now)
                XCTAssertFalse(presentation.isOnline); XCTAssertNil(presentation.nextRefresh)
                XCTAssertFalse(presentation.text.contains("1970"))
            }
        }
        let active = status(.recently(isHidden: true), activity: 990)
        XCTAssertTrue(active.presentation(now: now).isOnline)
        XCTAssertEqual(active.presentation(now: now).nextRefresh, Date(timeIntervalSince1970: 1020))
        XCTAssertEqual(active.presentation(now: Date(timeIntervalSince1970: 1020)).text, "Был(а) недавно")
    }
    func testMissingSelfBotSupportServiceAndUnknownCounts() {
        XCTAssertEqual(status().presentation(now: now).text, "Статус недоступен")
        XCTAssertEqual(status(.some(.none)).presentation(now: now).text, "Был(а) давно")
        XCTAssertEqual(status(.present(until: 2000), selfPeer: true).presentation(now: now).text, "")
        XCTAssertEqual(status(.present(until: 2000), kind: .bot).presentation(now: now).text, "Бот")
        XCTAssertEqual(status(support: true).presentation(now: now).text, "Поддержка Telegram")
        XCTAssertEqual(status(service: true).presentation(now: now).text, "Служебные уведомления")
        XCTAssertEqual(status(kind: .channel).presentation(now: now).text, "Канал")
        XCTAssertEqual(status(kind: .supergroup).presentation(now: now).text, "Группа")
        XCTAssertEqual(status(kind: .group, count: 0).presentation(now: now).text, "0 участников")
        XCTAssertEqual(status(kind: .channel, count: 0).presentation(now: now).text, "0 подписчиков")
        XCTAssertNil(status(kind: .group, count: -1).memberCount)
    }
    private func user(namespace: PeerId.Namespace = Namespaces.Peer.CloudUser, bot: Bool = false,
                      flags: UserInfoFlags = [], phone: String? = nil) -> TelegramUser {
        TelegramUser(id: PeerId(namespace: namespace, id: ._internalFromInt64Value(42)), accessHash: nil,
            firstName: "Synthetic", lastName: nil, username: nil, phone: phone, photo: [],
            botInfo: bot ? BotUserInfo(flags: [], inlinePlaceholder: nil) : nil, restrictionInfo: nil,
            flags: flags, emojiStatus: nil, usernames: [], storiesHidden: nil, nameColor: nil,
            backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil,
            verificationIconFileId: nil)
    }
    func testNativePresenceMappingAndAccountAttribution() throws {
        let peer = user()
        let native = TelegramUserPresence(status: .recently(isHidden: true), lastActivity: 990)
        let first = try XCTUnwrap(telegramPeerStatus(peer: peer, presence: native, cachedData: nil, accountID: 1, serverTimeOffset: 25))
        let second = try XCTUnwrap(telegramPeerStatus(peer: peer, presence: native, cachedData: nil, accountID: 2, serverTimeOffset: -25))
        XCTAssertEqual(first.presence, .recently(isHidden: true)); XCTAssertEqual(first.lastActivity, 990)
        XCTAssertEqual(first.serverTimeOffset, 25); XCTAssertEqual(first.accountID, 1)
        XCTAssertEqual(second.accountID, 2); XCTAssertEqual(first.peerID, peer.id.toInt64())
        XCTAssertNotEqual(first, second)
        let empty = try XCTUnwrap(telegramPeerStatus(peer: peer, presence: TelegramUserPresence(status: .none, lastActivity: 0), cachedData: nil, accountID: 1, serverTimeOffset: 0))
        XCTAssertEqual(empty.presence, TelegramPeerStatus.Presence.none)
        XCTAssertNil(telegramPeerStatus(peer: user(namespace: Namespaces.Peer.SecretChat), presence: native, cachedData: nil, accountID: 1, serverTimeOffset: 0))
        XCTAssertTrue(try XCTUnwrap(telegramPeerStatus(peer: user(flags: [.isSupport]), presence: nil, cachedData: nil, accountID: 1, serverTimeOffset: 0)).isSupport)
        XCTAssertTrue(try XCTUnwrap(telegramPeerStatus(peer: user(phone: "42777"), presence: nil, cachedData: nil, accountID: 1, serverTimeOffset: 0)).isService)
        XCTAssertEqual(try XCTUnwrap(telegramPeerStatus(peer: user(bot: true), presence: native, cachedData: nil, accountID: 1, serverTimeOffset: 0)).kind, .bot)
    }
    func testNativeGroupAndChannelCountAbsenceAndZero() throws {
        let group = TelegramGroup(id: PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(42)),
            title: "Synthetic", photo: [], participantCount: 0, role: .member, membership: .Member,
            flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 1)
        let basic = try XCTUnwrap(telegramPeerStatus(peer: group, presence: nil, cachedData: nil, accountID: 1, serverTimeOffset: 0))
        XCTAssertEqual(basic.kind, .group); XCTAssertEqual(basic.memberCount, 0)
        let channel = TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(42)),
            accessHash: nil, title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
            participationStatus: .member, info: .broadcast(TelegramChannelBroadcastInfo(flags: [])),
            flags: [], restrictionInfo: nil, adminRights: nil, bannedRights: nil, defaultBannedRights: nil,
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil,
            subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: nil, linkedMonoforumId: nil)
        let unknown = try XCTUnwrap(telegramPeerStatus(peer: channel, presence: nil, cachedData: nil, accountID: 1, serverTimeOffset: 0))
        XCTAssertEqual(unknown.kind, .channel); XCTAssertNil(unknown.memberCount)
        let cache = CachedChannelData().withUpdatedParticipantsSummary(CachedChannelParticipantsSummary(
            memberCount: 0, adminCount: nil, bannedCount: nil, kickedCount: nil))
        let zero = try XCTUnwrap(telegramPeerStatus(peer: channel, presence: nil, cachedData: cache, accountID: 1, serverTimeOffset: 0))
        XCTAssertEqual(zero.memberCount, 0); XCTAssertNotEqual(unknown, zero)
    }

    func testAbsoluteUnixLastSeenDoesNotShiftByServerClockOffset() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let value = status(.present(until: 10000), offset: 3600)
        let presented = value.presentation(now: Date(timeIntervalSince1970: 20000), timeZone: utc)
        XCTAssertEqual(presented.text, "Был(а) 01.01.1970 02:46")
        XCTAssertFalse(presented.isOnline)
        XCTAssertNil(presented.nextRefresh)
        let oppositeOffset = status(.present(until: 10000), offset: -3600)
        XCTAssertEqual(oppositeOffset.presentation(now: Date(timeIntervalSince1970: 20000), timeZone: utc).text, presented.text)
    }
    func testRussianMemberAndSubscriberPluralForms() {
        for (count, suffix) in [(1, "участник"), (2, "участника"), (5, "участников"), (11, "участников"),
                                (14, "участников"), (21, "участник"), (22, "участника"), (25, "участников"), (111, "участников")] {
            XCTAssertEqual(status(kind: .group, count: count).presentation(now: now).text, "\(count) \(suffix)")
        }
        for (count, suffix) in [(1, "подписчик"), (2, "подписчика"), (5, "подписчиков"), (11, "подписчиков"), (21, "подписчик")] {
            XCTAssertEqual(status(kind: .channel, count: count).presentation(now: now).text, "\(count) \(suffix)")
        }
    }

}
