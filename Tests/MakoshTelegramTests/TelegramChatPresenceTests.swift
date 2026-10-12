import XCTest
import Foundation
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramChatPresenceTests: XCTestCase {
    private func value(_ status: UserPresenceStatus, activity: Int32 = 0,
                       offset: Double = 0, account: Int64 = 1, peer: Int64 = 2) -> TelegramChatPresence? {
        telegramChatPresence(presence: TelegramUserPresence(status: status, lastActivity: activity),
            accountID: account, peerID: peer, serverTimeOffset: offset)
    }

    func testInclusiveNativeSecondTruncatedServerOffsetAndExpiry() throws {
        for (offset, expiry) in [(90.9, 1011.0), (-90.9, 1191.0), (0.0, 1101.0)] {
            let observation = try XCTUnwrap(value(.present(until: 1100), offset: offset))
            XCTAssertEqual(observation.expiresAt, Date(timeIntervalSince1970: expiry))
            XCTAssertTrue(observation.isOnline(now: Date(timeIntervalSince1970: expiry - 0.001)))
            XCTAssertFalse(observation.isOnline(now: observation.expiresAt))
            XCTAssertFalse(observation.isOnline(now: observation.expiresAt.addingTimeInterval(1)))
        }
    }

    func testRecentlyActivityPrivacyBucketsAndSafeArithmetic() throws {
        for hidden in [true, false] {
            let active = try XCTUnwrap(value(.recently(isHidden: hidden), activity: 990, offset: -10.9))
            XCTAssertEqual(active.expiresAt, Date(timeIntervalSince1970: 1031))
            XCTAssertTrue(active.isOnline(now: Date(timeIntervalSince1970: 1030.9)))
            XCTAssertFalse(active.isOnline(now: Date(timeIntervalSince1970: 1031)))
            XCTAssertNil(value(.lastWeek(isHidden: hidden)))
            XCTAssertNil(value(.lastMonth(isHidden: hidden)))
        }
        let overflow = try XCTUnwrap(value(.recently(isHidden: false), activity: Int32.max))
        XCTAssertEqual(overflow.expiresAt.timeIntervalSince1970, Double(Int32.max) + 31)
        for offset in [Double.infinity, -.infinity, .nan, Double(Int32.max) + 1] {
            XCTAssertNil(value(.present(until: 1100), offset: offset))
        }
        XCTAssertFalse(try XCTUnwrap(value(.present(until: 1100))).isOnline(now: Date(timeIntervalSince1970: .nan)))
    }

    func testMissingSelfAndExactServiceIdentityWithAccountAttribution() throws {
        XCTAssertNil(telegramChatPresence(presence: nil, accountID: 1, peerID: 2, serverTimeOffset: 0))
        XCTAssertNil(value(.none))
        XCTAssertNil(value(.present(until: 1100), account: 2, peer: 2))
        let service = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(777000)).toInt64()
        XCTAssertNil(value(.present(until: 1100), peer: service))
        let sameNumberInAnotherNamespace = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(777000)).toInt64()
        XCTAssertNotNil(value(.present(until: 1100), peer: sameNumberInAnotherNamespace))
        let first = try XCTUnwrap(value(.present(until: 1100), account: 1))
        let second = try XCTUnwrap(value(.present(until: 1100), account: 3))
        XCTAssertEqual(first.accountID, 1); XCTAssertEqual(second.accountID, 3)
        XCTAssertEqual(first.peerID, 2); XCTAssertNotEqual(first, second)
    }

    #if DEBUG
    @MainActor func testSearchPresenceUpdatesRemainScopedToCurrentRequestAndFolder() throws {
        let search = TelegramSearchModel()
        search.useSyntheticPreview()
        search.chatQuery = "Synthetic first"
        let stale = try XCTUnwrap(search.chatRequestID)
        search.chatQuery = "Synthetic second"
        let current = try XCTUnwrap(search.chatRequestID)
        var chat = TelegramChat(id: 2, title: "Synthetic", preview: "Local", unreadCount: 0)
        chat.presence = value(.present(until: 1100))
        search.receiveChats([chat], requestID: current)
        XCTAssertEqual(search.chats, [chat])
        chat.presence = nil
        search.receiveChats([chat], requestID: current)
        XCTAssertNil(search.chats.first?.presence)
        chat.presence = value(.present(until: 1200), account: 3)
        search.receiveChats([chat], requestID: stale)
        XCTAssertNil(search.chats.first?.presence)
        search.setFolder(.archive)
        search.receiveChats([chat], requestID: current)
        XCTAssertTrue(search.chats.isEmpty)
        search.bind(account: nil)
        XCTAssertTrue(search.chats.isEmpty); XCTAssertNil(search.chatRequestID)
    }
    #endif
}
