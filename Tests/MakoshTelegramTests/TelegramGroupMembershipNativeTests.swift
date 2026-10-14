import XCTest
import TelegramCore
import TelegramApi
import Postbox
@testable import MakoshTelegram

final class TelegramGroupMembershipNativeTests: XCTestCase {
    private var basis: TelegramGroupMembershipSnapshot {
        .init(accountID: 101, peerID: 4_294_967_306, title: "Synthetic", basic: true, isCreator: true,
            canInvite: true, canManageLinks: true, canRequests: true, canHistory: false)
    }
    private func invite(_ n: Int32, revoked: Bool = false) -> Api.ExportedChatInvite {
        .chatInviteExported(flags: revoked ? 1 : 0, link: "https://t.me/+Synthetic\(n)", adminId: 101,
            date: 1000 - n, startDate: nil, expireDate: nil, usageLimit: nil, usage: nil, requested: nil,
            subscriptionExpired: nil, title: nil, subscriptionPricing: nil)
    }
    func testNativeCountAndCursorDetermineShortPageContinuation() throws {
        let value = try XCTUnwrap(telegramGroupLinkPage(snapshot: basis, ownerID: 101,
            result: .exportedChatInvites(count: 3, invites: [invite(1), invite(2)], users: []), revoked: false, cursor: nil))
        XCTAssertEqual(value.links.count, 2)
        XCTAssertEqual(value.next, .links(date: 998, link: "https://t.me/+Synthetic2", seen: 2))
        XCTAssertNil(telegramGroupLinkPage(snapshot: basis, ownerID: 101,
            result: .exportedChatInvites(count: 3, invites: [], users: []), revoked: false, cursor: nil))
        XCTAssertNil(telegramGroupLinkPage(snapshot: basis, ownerID: 101,
            result: .exportedChatInvites(count: 1, invites: [invite(1), invite(2)], users: []), revoked: false, cursor: nil))
    }
    func testNativeLinkPageRejectsDuplicatesWrongOwnerAndRevokedState() {
        for entries in [[invite(1), invite(1)], [invite(1, revoked: true)]] {
            XCTAssertNil(telegramGroupLinkPage(snapshot: basis, ownerID: 101,
                result: .exportedChatInvites(count: 2, invites: entries, users: []), revoked: false, cursor: nil))
        }
        XCTAssertNil(telegramGroupLinkPage(snapshot: basis, ownerID: 102,
            result: .exportedChatInvites(count: 1, invites: [invite(1)], users: []), revoked: false, cursor: nil))
    }
    func testInvitationAckRequiresExactMissingInviteeSemantics() throws {
        let updates = Api.Updates.updates(updates: [], users: [], chats: [], date: 1, seq: 1)
        XCTAssertNoThrow(try telegramGroupInvitationAck(.invitedUsers(updates: updates, missingInvitees: []), userID: 7).get())
        guard case .failure(.privacyLimited) = telegramGroupInvitationAck(
            .invitedUsers(updates: updates, missingInvitees: [.missingInvitee(flags: 0, userId: 7)]), userID: 7)
        else { return XCTFail("Exact privacy refusal must remain explicit") }
        guard case .failure(.uncertain) = telegramGroupInvitationAck(
            .invitedUsers(updates: updates, missingInvitees: [.missingInvitee(flags: 0, userId: 8)]), userID: 7)
        else { return XCTFail("An unrelated missing user cannot confirm this invite") }
    }
    func testRequestPacketRequiresPendingFlagsAndCompletePeerIdentity() throws {
        let id = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(7))
        let user = TelegramUser(id: id, accessHash: .personal(77), firstName: "Alice", lastName: nil, username: "alice",
            phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        let pending = Api.ChatInviteImporter.chatInviteImporter(flags: 1, userId: 7, date: 1000, about: "QA", approvedBy: nil)
        let packet = Api.messages.ChatInviteImporters.chatInviteImporters(count: 2, importers: [pending], users: [])
        let value = try XCTUnwrap(telegramGroupRequestPage(snapshot: basis, result: packet, peers: [id: user], cursor: nil))
        XCTAssertEqual(value.requests.first?.title, "Alice"); XCTAssertEqual(value.next, .requests(date: 1000, userID: 7, seen: 1))
        XCTAssertNil(telegramGroupRequestPage(snapshot: basis, result: packet, peers: [:], cursor: nil))
        XCTAssertNil(telegramGroupRequestPage(snapshot: basis,
            result: .chatInviteImporters(count: 1, importers: [.chatInviteImporter(flags: 0, userId: 7, date: 1000, about: nil, approvedBy: 101)], users: []),
            peers: [id: user], cursor: nil))
    }
    func testRevokeAckMustNameTheExactRevokedLink() {
        let old = telegramGroupInviteLink(invite(1))!
        XCTAssertTrue(telegramGroupRevokeAck(.exportedChatInvite(invite: invite(1, revoked: true), users: []), expected: old))
        XCTAssertFalse(telegramGroupRevokeAck(.exportedChatInvite(invite: invite(2, revoked: true), users: []), expected: old))
        XCTAssertFalse(telegramGroupRevokeAck(.exportedChatInvite(invite: invite(1), users: []), expected: old))
        XCTAssertFalse(telegramGroupRevokeAck(.exportedChatInviteReplaced(invite: invite(1, revoked: true), newInvite: invite(1), users: []), expected: old))
    }
    func testBasicCreatorAndDefaultInviteBanHaveDifferentAuthorities() {
        let id = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(10))
        func group(_ role: TelegramGroupRole, banned: Bool = false) -> TelegramGroup {
            .init(id: id, title: "Synthetic", photo: [], participantCount: 2, role: role, membership: .Member, flags: [],
                defaultBannedRights: banned ? .init(flags: [.banAddMembers], untilDate: Int32.max) : nil, migrationReference: nil, creationDate: 0, version: 1)
        }
        let member = telegramGroupMembershipSnapshot(peer: group(.member), accountID: 101)
        XCTAssertEqual(member?.canInvite, true); XCTAssertEqual(member?.canManageLinks, false)
        XCTAssertEqual(telegramGroupMembershipSnapshot(peer: group(.member, banned: true), accountID: 101)?.canInvite, false)
        let creator = telegramGroupMembershipSnapshot(peer: group(.creator(rank: nil)), accountID: 101)
        XCTAssertEqual(creator?.canManageLinks, true); XCTAssertEqual(creator?.canRequests, true); XCTAssertEqual(creator?.canHistory, false)
    }
    func testCreateAndRevokeWireCarryOnlyConsentedFlags() throws {
        let peer = Api.InputPeer.inputPeerChat(chatId: 10)
        let draft = TelegramGroupInviteDraft(title: "QA", expireDate: nil, usageLimit: 2, requiresApproval: false)
        let create = try XCTUnwrap(telegramGroupCreateInviteRPC(peer: peer, draft: draft))
        XCTAssertEqual(create.0.name, "messages.exportChatInvite")
        XCTAssertEqual(String(describing: create.0.parameters[0].1), "18")
        let approve = try XCTUnwrap(telegramGroupCreateInviteRPC(peer: peer, draft: .init(title: "", expireDate: nil, usageLimit: nil, requiresApproval: true)))
        XCTAssertEqual(String(describing: approve.0.parameters[0].1), "8")
        let revoke = try XCTUnwrap(telegramGroupRevokeInviteRPC(peer: peer, link: "https://t.me/+Synthetic"))
        XCTAssertEqual(revoke.0.name, "messages.editExportedChatInvite"); XCTAssertEqual(String(describing: revoke.0.parameters[0].1), "4")
        XCTAssertNil(telegramGroupCreateInviteRPC(peer: .inputPeerEmpty, draft: draft))
        XCTAssertNil(telegramGroupRevokeInviteRPC(peer: peer, link: "https://evil.invalid/+Synthetic"))
    }
    func testLeftBannedAndWrongParticipantCannotConfirmMembership() {
        XCTAssertTrue(telegramGroupParticipantIsMember(.channelParticipant(flags: 0, userId: 7, date: 1, subscriptionUntilDate: nil), userID: 7))
        XCTAssertFalse(telegramGroupParticipantIsMember(.channelParticipant(flags: 0, userId: 8, date: 1, subscriptionUntilDate: nil), userID: 7))
        XCTAssertFalse(telegramGroupParticipantIsMember(.channelParticipantLeft(peer: .peerUser(userId: 7)), userID: 7))
        XCTAssertFalse(telegramGroupParticipantIsMember(.channelParticipantBanned(flags: 1, peer: .peerUser(userId: 7), kickedBy: 101,
            date: 1, bannedRights: .chatBannedRights(flags: 0, untilDate: Int32.max)), userID: 7))
        XCTAssertFalse(telegramGroupParticipantIsMember(.channelParticipantBanned(flags: 0, peer: .peerUser(userId: 7), kickedBy: 101,
            date: 1, bannedRights: .chatBannedRights(flags: 1, untilDate: Int32.max)), userID: 7))
    }
    func testForeignParticipantIsUnknownRatherThanEvidenceOfAbsence() {
        XCTAssertEqual(telegramGroupParticipantMembership(.channelParticipantLeft(peer: .peerUser(userId: 7)), userID: 7), false)
        XCTAssertNil(telegramGroupParticipantMembership(.channelParticipantLeft(peer: .peerUser(userId: 8)), userID: 7))
        XCTAssertNil(telegramGroupParticipantMembership(.channelParticipant(flags: 0, userId: 8, date: 1, subscriptionUntilDate: nil), userID: 7))
    }
}
