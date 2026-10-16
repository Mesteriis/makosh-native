import XCTest
import TelegramApi
import TelegramCore
import Postbox
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramBlockedUsersNativeTests: XCTestCase {
    func testNonUserBlockedPeersDoNotInvalidateUserMembershipOrRawPagination() {
        var offsets: [Int32] = [], values: [TelegramBlockedUsersSnapshot] = [], errors: [TelegramPrivacyError] = []
        let d = telegramLoadBlockedUsers(accountID: 1) { offset in
            offsets.append(offset)
            let peers: [Api.Peer] = offset == 0 ? [.peerUser(userId: 7), .peerChannel(channelId: 7)] : [.peerChat(chatId: 7)]
            return .single(.blockedSlice(count: 3, blocked: peers.map { .peerBlocked(peerId: $0, date: 1) }, chats: [], users: []))
        }.start(next: { values.append($0) }, error: { errors.append($0) })
        defer { d.dispose() }
        XCTAssertEqual(offsets, [0, 2])
        XCTAssertEqual(values.first?.users.map(\.id), [7])
        XCTAssertEqual(values.first?.otherPeers.map(\.id), ["channel:7", "group:7"])
        XCTAssertTrue(values.first?.isValid == true)
        XCTAssertTrue(errors.isEmpty)
    }

    static func user(_ id: Int64, min: Bool = false, hash: Int64? = 70) -> Api.User {
        .user(flags: (hash == nil ? 6 : 7) | (min ? 1 << 20 : 0), flags2: 0, id: id, accessHash: hash, firstName: "Synthetic", lastName: "Alice",
            username: nil, phone: nil, photo: nil, status: nil, botInfoVersion: nil, restrictionReason: nil,
            botInlinePlaceholder: nil, langCode: nil, emojiStatus: nil, usernames: nil, storiesMaxId: nil, color: nil,
            profileColor: nil, botActiveUsers: nil, botVerificationIcon: nil, sendPaidMessagesStars: nil)
    }
    func testFreshServerIdentityWorksWithoutLocalCacheButRejectsMinMissingAndSelfHashes() throws {
        let input = try XCTUnwrap(telegramBlockedServerInput(Self.user(7), selfID: 1))
        guard case let .inputPeerUser(id, hash) = input else { return XCTFail("Server cloud user input required") }
        XCTAssertEqual(id, 7); XCTAssertEqual(hash, 70)
        for user in [Self.user(7,min: true),Self.user(7,hash: nil),Self.user(7,hash: 0),Self.user(1),Self.user(Int64.max),.userEmpty(id: 7)] {
            XCTAssertNil(telegramBlockedServerInput(user, selfID: 1))
        }
        let value = try XCTUnwrap(telegramBlockedPage(.blocked(blocked: [.peerBlocked(peerId: .peerUser(userId: 7), date: 1)], chats: [], users: [Self.user(7)]), offset: 0))
        XCTAssertEqual(value.users, [.init(id: 7,title: "Synthetic Alice")])
        guard case let .inputPeerUser(serverID, serverHash) = value.serverInputs[7] else { return XCTFail("Fresh server hash required") }
        XCTAssertEqual(serverID, 7); XCTAssertEqual(serverHash, 70)
    }
    static func page(_ ids: [Int64], total: Int32? = nil) -> Api.contacts.Blocked {
        let blocked = ids.map { Api.PeerBlocked.peerBlocked(peerId: .peerUser(userId: $0), date: 1) }
        if let total { return .blockedSlice(count: total, blocked: blocked, chats: [], users: []) }
        return .blocked(blocked: blocked, chats: [], users: [])
    }
    func testMissingUserObjectsRetainEveryBlockedIdentityAndRawOffset() throws {
        let page = try XCTUnwrap(telegramBlockedPage(Self.page([7,8], total: 3), offset: 0))
        XCTAssertEqual(page.users.map(\.id), [7,8]); XCTAssertEqual(page.nextOffset, 2)
        XCTAssertEqual(page.users.map(\.title), ["Недоступное имя", "Недоступное имя"])
        XCTAssertEqual(page.totalCount, 3)
        XCTAssertNil(telegramBlockedPage(Self.page([7,7]), offset: 0))
        XCTAssertNil(telegramBlockedPage(Self.page([0]), offset: 0))
        XCTAssertNil(telegramBlockedPage(Self.page([], total: 3), offset: 0))
        XCTAssertNil(telegramBlockedPage(Self.page([7], total: 10_001), offset: 0))
        XCTAssertEqual(telegramBlockedPage(.blocked(blocked: [.peerBlocked(peerId: .peerChat(chatId: 7), date: 1)], chats: [], users: []), offset: 0)?.otherPeers.map(\.id), ["group:7"])
    }
    func testNonUserPeersStillRejectInvalidIDsAndRepeatedPages() {
        XCTAssertNil(telegramBlockedPage(.blocked(blocked: [.peerBlocked(peerId: .peerChannel(channelId: 0), date: 1)], chats: [], users: []), offset: 0))
        var errors: [TelegramPrivacyError] = [], values: [TelegramBlockedUsersSnapshot] = []
        let d = telegramLoadBlockedUsers(accountID: 1) { _ in
            .single(.blockedSlice(count: 2, blocked: [.peerBlocked(peerId: .peerChannel(channelId: 7), date: 1)], chats: [], users: []))
        }.start(next: { values.append($0) }, error: { errors.append($0) })
        defer { d.dispose() }
        XCTAssertTrue(values.isEmpty); XCTAssertEqual(errors, [.failed])
    }
    func testCompletePaginationUsesRawOffsetsAndRefusesRepeatedOrMovingPages() {
        for mode in 0...2 {
            var offsets: [Int32] = [], values: [TelegramBlockedUsersSnapshot] = [], errors: [TelegramPrivacyError] = []
            let d = telegramLoadBlockedUsers(accountID: 1) { offset in
                offsets.append(offset)
                if offset == 0 { return .single(Self.page([7,8], total: 3)) }
                return .single(Self.page([mode == 1 ? 8 : 9], total: mode == 2 ? 4 : 3))
            }.start(next: { values.append($0) }, error: { errors.append($0) })
            defer { d.dispose() }
            if mode == 0 { XCTAssertEqual(values.first?.users.map(\.id), [7,8,9]); XCTAssertTrue(errors.isEmpty) }
            else { XCTAssertTrue(values.isEmpty); XCTAssertEqual(errors, [.failed]) }
            XCTAssertEqual(offsets, [0,2])
        }
    }
    func testTypedRPCUsesNormalBlockFlagAndPersonalCloudUserIdentity() throws {
        let user = TelegramUser(id: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(7)),
            accessHash: .personal(70), firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
            photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        let input = try XCTUnwrap(telegramBlockedInput(user: user, selfID: 1))
        guard case let .inputPeerUser(id, hash) = input else { return XCTFail("Cloud user input required") }
        XCTAssertEqual(id, 7); XCTAssertEqual(hash, 70)
        XCTAssertNil(telegramBlockedInput(user: user, selfID: 7))
        for block in [true,false] {
            let rpc = telegramBlockedRPC(block: block, input: input)
            XCTAssertEqual(rpc.0.name, block ? "contacts.block" : "contacts.unblock")
            let reader = BufferReader(rpc.1); _ = reader.readInt32(); XCTAssertEqual(reader.readInt32(), 0)
        }
    }
    func testFreshMembershipAccountAndTrueAcknowledgementAreRequired() {
        for mode in 0...5 {
            let change = TelegramBlockedUserChange(accountID: 1, contextID: UUID(), userID: 7, title: "Synthetic Alice", wasBlocked: true)
            var sent = 0, successes = 0, errors: [TelegramPrivacyError] = []
            let d = telegramPerformBlockedChange(accountID: mode == 1 ? 2 : 1, change: change,
                load: { .single(.init(accountID: 1, users: mode == 2 ? [] : [.init(id: 7, title: "Synthetic Alice")])) },
                perform: { sent += 1; return mode == 3 ? .complete() : mode == 4 ? .single(.boolFalse) : mode == 5 ? .fail(.uncertain) : .single(.boolTrue) })
                .start(next: { successes += 1 }, error: { errors.append($0) })
            defer { d.dispose() }
            XCTAssertEqual(sent, mode == 1 || mode == 2 ? 0 : 1)
            XCTAssertEqual(successes, mode == 0 ? 1 : 0)
            XCTAssertEqual(errors, mode == 0 ? [] : [mode == 1 || mode == 2 ? .changed : .uncertain])
        }
    }
}
