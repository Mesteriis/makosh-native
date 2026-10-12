import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramPeerManagementTests: XCTestCase {
    private func group(role: TelegramGroupRole = .member, membership: TelegramGroupMembership = .Member,
        flags: TelegramGroupFlags = [], bans: TelegramChatBannedRightsFlags = [],
        migrated: Bool = false) -> TelegramGroup {
        TelegramGroup(id: PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(7)),
            title: "Synthetic", photo: [], participantCount: 2, role: role, membership: membership,
            flags: flags, defaultBannedRights: TelegramChatBannedRights(flags: bans, untilDate: Int32.max),
            migrationReference: migrated ? TelegramGroupToChannelMigrationReference(
                peerId: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(8)),
                accessHash: 1) : nil, creationDate: 0, version: 1)
    }

    private func channel(broadcast: Bool = false, participation: TelegramChannelParticipationStatus = .member,
        flags: TelegramChannelFlags = [], groupFlags: TelegramChannelGroupFlags = [],
        admin: TelegramChatAdminRightsFlags? = nil, bans: TelegramChatBannedRightsFlags = [],
        defaultBans: TelegramChatBannedRightsFlags = [], fee: StarsAmount? = nil) -> TelegramChannel {
        TelegramChannel(id: PeerId(namespace: Namespaces.Peer.CloudChannel, id: ._internalFromInt64Value(9)),
            accessHash: .personal(101), title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
            participationStatus: participation,
            info: broadcast ? .broadcast(TelegramChannelBroadcastInfo(flags: []))
                : .group(TelegramChannelGroupInfo(flags: groupFlags)), flags: flags, restrictionInfo: nil,
            adminRights: admin.map { TelegramChatAdminRights(rights: $0) },
            bannedRights: TelegramChatBannedRights(flags: bans, untilDate: 2_100),
            defaultBannedRights: TelegramChatBannedRights(flags: defaultBans, untilDate: Int32.max),
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, emojiStatus: nil, approximateBoostLevel: nil,
            subscriptionUntilDate: nil, verificationIconFileId: nil, sendPaidMessageStars: fee,
            linkedMonoforumId: nil)
    }

    func testNativeRolesMembershipMigrationAndMissingCacheFailClosed() throws {
        let allowed = try XCTUnwrap(telegramPeerManagement(peer: group(), cachedData: CachedGroupData(), accountID: 1))
        XCTAssertTrue(allowed.canEditInfo); XCTAssertTrue(allowed.canViewMembers)
        XCTAssertFalse(allowed.canPromote); XCTAssertFalse(allowed.canRestrict)
        let banned = try XCTUnwrap(telegramPeerManagement(peer: group(bans: [.banChangeInfo]), cachedData: CachedGroupData(), accountID: 1))
        XCTAssertFalse(banned.canEditInfo)
        XCTAssertNil(telegramPeerManagement(peer: group(membership: .Left), cachedData: CachedGroupData(), accountID: 1))
        XCTAssertNil(telegramPeerManagement(peer: group(migrated: true), cachedData: CachedGroupData(), accountID: 1))
        XCTAssertNil(telegramPeerManagement(peer: group(), cachedData: nil, accountID: 1))
        XCTAssertNil(telegramPeerManagement(peer: channel(), cachedData: CachedUserData(), accountID: 1))
        XCTAssertNil(telegramPeerManagement(peer: channel(participation: .left), cachedData: CachedChannelData(), accountID: 1))
        XCTAssertNil(telegramPeerManagement(peer: channel(flags: [.isMonoforum]), cachedData: CachedChannelData(), accountID: 1))
    }
    func testNativeChannelRightsAreIndependentAndNeverGrantBeyondAccount() throws {
        let rights: TelegramChatAdminRightsFlags = [.canChangeInfo, .canAddAdmins, .canDeleteMessages]
        let value = try XCTUnwrap(telegramPeerManagement(peer: channel(admin: rights), cachedData: CachedChannelData(), accountID: 22))
        XCTAssertEqual(value.accountID, 22); XCTAssertEqual(value.peerID, channel().id.toInt64())
        XCTAssertTrue(value.canEditInfo); XCTAssertTrue(value.canPromote); XCTAssertFalse(value.canRestrict)
        XCTAssertEqual(value.grantableRights, rights.rawValue)
        let member = TelegramPeerMember(id: 42, title: "Test", role: .member, adminRights: 0, bannedRights: 0, untilDate: 0, rank: nil, editable: true)
        XCTAssertTrue(value.permits(.administrator(member: member, rights: TelegramChatAdminRightsFlags.canDeleteMessages.rawValue, rank: "Editor")))
        XCTAssertFalse(value.permits(.administrator(member: member, rights: TelegramChatAdminRightsFlags.canBanUsers.rawValue, rank: "")))
        XCTAssertFalse(value.permits(.administrator(member: member, rights: Int32.max, rank: "")))
        let protected = TelegramPeerMember(id: 43, title: "Owner", role: .creator, adminRights: 0, bannedRights: 0, untilDate: 0, rank: nil, editable: false)
        XCTAssertFalse(value.permits(.administrator(member: protected, rights: 0, rank: "")))
        XCTAssertFalse(value.permits(.administrator(member: member, rights: 0, rank: String(repeating: "x", count: 17))))
        let own = TelegramPeerMember(id: 22, title: "Self", role: .member, adminRights: 0, bannedRights: 0, untilDate: 0, rank: nil, editable: true)
        XCTAssertFalse(value.permits(.administrator(member: own, rights: 0, rank: "")))
    }
    func testInfoEditsUseCurrentBasisAndValidatedReferenceLimits() throws {
        let value = try XCTUnwrap(telegramPeerManagement(peer: channel(flags: [.isCreator]), cachedData: CachedChannelData().withUpdatedAbout("About"), accountID: 1))
        XCTAssertTrue(value.permits(.title(previous: "Synthetic", value: "New name")))
        XCTAssertFalse(value.permits(.title(previous: "Old", value: "New name")))
        XCTAssertFalse(value.permits(.title(previous: "Synthetic", value: "   ")))
        XCTAssertFalse(value.permits(.title(previous: "Synthetic", value: String(repeating: "x", count: 256))))
        XCTAssertTrue(value.permits(.about(previous: "About", value: "")))
        XCTAssertFalse(value.permits(.about(previous: nil, value: "Other")))
        XCTAssertFalse(value.permits(.about(previous: "About", value: String(repeating: "x", count: 256))))
    }
    func testRestrictionCannotSilentlyDemoteAdministratorOrAffectSelf() throws {
        let value = try XCTUnwrap(telegramPeerManagement(peer: channel(admin: [.canBanUsers]), cachedData: CachedChannelData(), accountID: 1))
        let member = TelegramPeerMember(id: 42, title: "Test", role: .member, adminRights: 0, bannedRights: 0, untilDate: 0, rank: nil, editable: true)
        XCTAssertTrue(value.permits(.restriction(member: member, rights: TelegramChatBannedRightsFlags.banReadMessages.rawValue, untilDate: Int32.max)))
        XCTAssertFalse(value.permits(.restriction(member: member, rights: Int32.max, untilDate: Int32.max)))
        XCTAssertFalse(value.permits(.restriction(member: member, rights: 0, untilDate: -1)))
        let admin = TelegramPeerMember(id: 43, title: "Admin", role: .administrator, adminRights: 1, bannedRights: 0, untilDate: 0, rank: nil, editable: true)
        XCTAssertFalse(value.permits(.restriction(member: admin, rights: 1, untilDate: Int32.max)))
    }
    func testBasicGroupOwnerUsesBooleanAdminAndRemovalWithoutGranularRights() throws {
        let owner = try XCTUnwrap(telegramPeerManagement(peer: group(role: .creator(rank: nil)), cachedData: CachedGroupData(), accountID: 1))
        let member = TelegramPeerMember(id: 42, title: "Member", role: .member, adminRights: 0, bannedRights: 0, untilDate: 0, rank: nil, editable: true)
        XCTAssertTrue(owner.canPromote); XCTAssertTrue(owner.canRestrict)
        XCTAssertTrue(owner.permits(.administrator(member: member, rights: 1, rank: "")))
        XCTAssertTrue(owner.permits(.administrator(member: member, rights: 0, rank: "")))
        XCTAssertFalse(owner.permits(.administrator(member: member, rights: 8, rank: "")))
        XCTAssertFalse(owner.permits(.administrator(member: member, rights: 1, rank: "Rank")))
        XCTAssertTrue(owner.permits(.restriction(member: member, rights: 1, untilDate: Int32.max)))
        XCTAssertFalse(owner.permits(.restriction(member: member, rights: 0, untilDate: Int32.max)))
        XCTAssertFalse(owner.permits(.restriction(member: member, rights: 1, untilDate: 100)))
        let administrator = try XCTUnwrap(telegramPeerManagement(peer: group(role: .admin(.init(rights: [.canBanUsers]), rank: nil)), cachedData: CachedGroupData(), accountID: 1))
        XCTAssertFalse(administrator.canPromote); XCTAssertTrue(administrator.canRestrict)
        XCTAssertTrue(administrator.permits(.restriction(member: member, rights: 1, untilDate: Int32.max)))
    }

    func testNativeAdminOtherBitAndRemovedLegacyBanBitsHaveExactWireSemantics() throws {
        XCTAssertEqual(telegramPeerAdminWireFlags(8), 4104)
        XCTAssertEqual(telegramPeerAdminWireFlags(0), 0, "Demotion must clear the mandatory other marker too")
        XCTAssertEqual(telegramPeerBannedWireFlags(6), 0, "Legacy aggregate media/send-message bits are absent in the current native wire")
        XCTAssertEqual(telegramPeerBannedWireFlags(33554433), 33554433)
        let snapshot = try XCTUnwrap(telegramPeerManagement(peer: channel(admin: [.canBanUsers]), cachedData: CachedChannelData(), accountID: 1))
        let member = TelegramPeerMember(id: 42, title: "Member", role: .member, adminRights: 0, bannedRights: 0, untilDate: 0, rank: nil, editable: true)
        XCTAssertFalse(snapshot.permits(.restriction(member: member, rights: 4, untilDate: Int32.max)))
    }

    func testDefaultPermissionsRequireCurrentBasisAndCannotBanReadingForEveryone() throws {
        let cache = CachedChannelData()
        let value = try XCTUnwrap(telegramPeerManagement(peer: channel(admin: [.canBanUsers], defaultBans: [.banSendText]), cachedData: cache, accountID: 1))
        XCTAssertEqual(value.defaultBannedRights, 33554432)
        XCTAssertTrue(value.permits(.permissions(previous: 33554432, value: 33554432 | 524288)))
        XCTAssertFalse(value.permits(.permissions(previous: 0, value: 524288)))
        XCTAssertFalse(value.permits(.permissions(previous: 33554432, value: 1)))
        XCTAssertFalse(value.permits(.permissions(previous: 33554432, value: Int32.max)))
        let member = try XCTUnwrap(telegramPeerManagement(peer: channel(defaultBans: [.banSendText]), cachedData: cache, accountID: 1))
        XCTAssertFalse(member.permits(.permissions(previous: 33554432, value: 0)))
    }

    func testFiniteRestrictionsCannotBecomePermanentAndTargetsMustBeUsers() throws {
        let value = try XCTUnwrap(telegramPeerManagement(peer: channel(flags: [.isCreator]), cachedData: CachedChannelData(), accountID: 1))
        let member = TelegramPeerMember(id: 42, title: "Member", role: .member, adminRights: 0, bannedRights: 0, untilDate: 0, rank: nil, editable: true)
        let now = Int32(Date().timeIntervalSince1970)
        for expiry in [Int32(0), now - 1, now + 10, now + 400 * 86400] {
            XCTAssertFalse(value.permits(.restriction(member: member, rights: 1, untilDate: expiry)), "Unsafe finite expiry: \(expiry)")
        }
        XCTAssertTrue(value.permits(.restriction(member: member, rights: 1, untilDate: now + 86400)))
        XCTAssertTrue(value.permits(.restriction(member: member, rights: 0, untilDate: Int32.max)))
        for raw in [Int64(0), Int64(-1), Int64.max, channel().id.toInt64(), group().id.toInt64()] {
            let invalid = TelegramPeerMember(id: raw, title: "Invalid", role: .member, adminRights: 0, bannedRights: 0, untilDate: 0, rank: nil, editable: true)
            XCTAssertFalse(value.permits(.administrator(member: invalid, rights: 8, rank: "")))
            XCTAssertFalse(value.permits(.restriction(member: invalid, rights: 1, untilDate: Int32.max)))
        }
    }

}
