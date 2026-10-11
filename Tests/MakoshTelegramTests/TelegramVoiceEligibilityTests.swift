import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramVoiceEligibilityTests: XCTestCase {
    private func user(namespace: PeerId.Namespace = Namespaces.Peer.CloudUser, flags: UserInfoFlags = [],
        bot: Bool = false) -> TelegramUser {
        TelegramUser(id: PeerId(namespace: namespace, id: ._internalFromInt64Value(42)), accessHash: nil,
            firstName: "Synthetic", lastName: nil, username: nil, phone: nil, photo: [],
            botInfo: bot ? BotUserInfo(flags: [], inlinePlaceholder: nil) : nil,
            restrictionInfo: nil, flags: flags, emojiStatus: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            subscriberCount: nil, verificationIconFileId: nil)
    }

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
            accessHash: nil, title: "Synthetic", username: nil, photo: [], creationDate: 0, version: 1,
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

    private func check(_ peer: Peer?, _ cache: CachedPeerData? = nil, now: Int32 = 2_000,
        pending: Bool = false) -> TelegramVoiceEligibility {
        telegramVoiceEligibility(peer: peer, cachedData: cache, now: now, hasPendingMessages: pending)
    }

    func testMissingAndWrongCacheNeverGrantUserOrChannelPermission() {
        XCTAssertEqual(check(nil), .unavailable)
        XCTAssertEqual(check(user()), .unavailable)
        XCTAssertEqual(check(user(), CachedChannelData()), .unavailable)
        XCTAssertEqual(check(channel()), .unavailable)
        XCTAssertEqual(check(channel(), CachedUserData()), .unavailable)
        XCTAssertEqual(check(group(), CachedUserData()), .unavailable)
        XCTAssertEqual(check(user(namespace: Namespaces.Peer.SecretChat), CachedUserData()), .unavailable)
    }

    func testCachedPrivacyAllowsCloudUsersSavedMessagesAndBotsOnlyWhenAvailable() {
        // Saved Messages uses the same cloud-user peer and fresh user-cache mapping as a person.
        for peer in [user(), user(bot: true)] {
            XCTAssertEqual(check(peer, CachedUserData()), .allowed)
            XCTAssertEqual(check(peer, CachedUserData().withUpdatedVoiceMessagesAvailable(false)), .voicePrivacy)
            XCTAssertEqual(check(peer, CachedUserData().withUpdatedIsBlocked(true)), .restricted)
        }
    }

    func testOutboundUserFeeIsExplicitAndUnrelatedInboundPriceDoesNotDenyVoice() {
        let fee = StarsAmount(value: 2, nanos: 0)
        XCTAssertEqual(check(user(), CachedUserData().withUpdatedSendPaidMessageStars(fee)), .paid)
        XCTAssertEqual(check(user(), CachedUserData().withUpdatedSendPaidMessageStars(
            StarsAmount(value: 0, nanos: 1))), .paid)
        XCTAssertEqual(check(user(flags: [.requireStars]), CachedUserData()), .paid)
        XCTAssertEqual(check(user(flags: [.requireStars]), CachedUserData().withUpdatedSendPaidMessageStars(.zero)), .allowed)
        let inboundFee = PeerStatusSettings(flags: [], paidMessageStars: fee)
        XCTAssertEqual(check(user(), CachedUserData().withUpdatedPeerStatusSettings(inboundFee)), .allowed)
    }

    func testBasicGroupRequiresMembershipAndCurrentNonMigratedPeer() {
        XCTAssertEqual(check(group()), .allowed)
        XCTAssertEqual(check(group(), CachedGroupData()), .allowed)
        XCTAssertEqual(check(group(membership: .Left)), .restricted)
        XCTAssertEqual(check(group(role: .creator(rank: nil), membership: .Removed)), .restricted)
        XCTAssertEqual(check(group(flags: [.deactivated])), .restricted)
        XCTAssertEqual(check(group(migrated: true)), .unavailable)
    }

    func testBasicGroupVoiceAndMediaBansAreIndependentOfTextAndFilePermissions() {
        for ban: TelegramChatBannedRightsFlags in [.banSendVoice, .banSendMedia, .banReadMessages] {
            XCTAssertEqual(check(group(bans: ban)), .restricted)
        }
        XCTAssertEqual(check(group(bans: [.banSendText, .banSendFiles, .banSendPhotos])), .allowed)
        XCTAssertEqual(check(group(role: .admin(TelegramChatAdminRights(rights: [.canDeleteMessages]), rank: nil),
            bans: [.banSendVoice, .banSendMedia])), .allowed)
        XCTAssertEqual(check(group(role: .creator(rank: nil), bans: [.banSendVoice])), .allowed)
    }

    func testChannelRequiresAccessMembershipAndSupportedChatShapeEvenForAdmin() {
        let cache = CachedChannelData()
        XCTAssertEqual(check(channel(), cache), .allowed)
        XCTAssertEqual(check(channel(participation: .left), cache), .restricted)
        XCTAssertEqual(check(channel(participation: .kicked, flags: [.isCreator]), cache), .restricted)
        XCTAssertEqual(check(channel(), cache.withUpdatedIsNotAccessible(true)), .restricted)
        XCTAssertEqual(check(channel(admin: [.canDeleteMessages]), cache.withUpdatedIsNotAccessible(true)), .restricted)
        XCTAssertEqual(check(channel(flags: [.isMonoforum]), cache), .unavailable)
    }

    func testBroadcastRequiresPostPermissionAndUnrelatedAdminRightsNeverGrantPosting() {
        let cache = CachedChannelData()
        XCTAssertEqual(check(channel(broadcast: true), cache), .restricted)
        XCTAssertEqual(check(channel(broadcast: true, admin: [.canDeleteMessages]), cache), .restricted)
        XCTAssertEqual(check(channel(broadcast: true, admin: [.canPostMessages]), cache), .allowed)
        XCTAssertEqual(check(channel(broadcast: true, flags: [.isCreator]), cache), .allowed)
    }

    func testSupergroupVoiceMediaAndReadBansCannotBeBypassedByOtherAllowedMedia() {
        let cache = CachedChannelData()
        for ban: TelegramChatBannedRightsFlags in [.banSendVoice, .banSendMedia, .banReadMessages] {
            XCTAssertEqual(check(channel(bans: ban), cache), .restricted)
            XCTAssertEqual(check(channel(defaultBans: ban), cache), .restricted)
        }
        XCTAssertEqual(check(channel(bans: [.banSendText, .banSendFiles, .banSendPhotos]), cache), .allowed)
        XCTAssertEqual(check(channel(admin: [.canDeleteMessages], bans: [.banSendVoice],
            defaultBans: [.banSendMedia]), cache), .allowed)
        XCTAssertEqual(check(channel(flags: [.isCreator], bans: [.banSendVoice]), cache), .allowed)
    }

    func testSlowModeDeadlineIsStrictAndPendingSendStillLocksAfterDeadline() {
        let peer = channel(groupFlags: [.slowModeEnabled])
        let cache = CachedChannelData().withUpdatedSlowModeTimeout(30).withUpdatedSlowModeValidUntilTimestamp(2_030)
        XCTAssertEqual(check(peer, cache, now: 2_029), .slowMode(until: 2_030))
        XCTAssertEqual(check(peer, cache, now: 2_030), .allowed)
        XCTAssertEqual(check(peer, cache, now: 2_031), .allowed)
        XCTAssertEqual(check(peer, cache, now: 2_030, pending: true), .slowMode(until: nil))
        XCTAssertEqual(check(peer, cache.withUpdatedSlowModeValidUntilTimestamp(nil), pending: true), .slowMode(until: nil))
        XCTAssertEqual(check(peer, cache.withUpdatedSlowModeValidUntilTimestamp(nil)), .allowed)
        XCTAssertEqual(check(peer, CachedChannelData().withUpdatedSlowModeValidUntilTimestamp(2_030)), .unavailable)
    }

    func testSlowModeOnlyAppliesToEnabledNonAdminSupergroups() {
        let cache = CachedChannelData().withUpdatedSlowModeTimeout(30).withUpdatedSlowModeValidUntilTimestamp(2_030)
        XCTAssertEqual(check(channel(), cache, pending: true), .allowed)
        XCTAssertEqual(check(channel(groupFlags: [.slowModeEnabled], admin: [.canDeleteMessages]), cache, pending: true), .allowed)
        XCTAssertEqual(check(channel(flags: [.isCreator], groupFlags: [.slowModeEnabled]), cache, pending: true), .allowed)
        XCTAssertEqual(check(channel(broadcast: true, admin: [.canPostMessages]), cache, pending: true), .allowed)
    }

    func testChannelFeesUseExplicitCachedWaiverAndNativeAdminExemption() {
        let fee = StarsAmount(value: 3, nanos: 0)
        XCTAssertEqual(check(channel(fee: fee), CachedChannelData()), .paid)
        XCTAssertEqual(check(channel(), CachedChannelData().withUpdatedSendPaidMessageStars(fee)), .paid)
        XCTAssertEqual(check(channel(fee: fee), CachedChannelData().withUpdatedSendPaidMessageStars(.zero)), .allowed)
        XCTAssertEqual(check(channel(admin: [.canDeleteMessages], fee: fee),
            CachedChannelData().withUpdatedSendPaidMessageStars(fee)), .allowed)
        XCTAssertEqual(check(channel(flags: [.isCreator], fee: fee), CachedChannelData()), .allowed)
    }

    func testBoostExemptionOnlyLiftsMediaBansAndNeverAccessReadOrSlowMode() {
        let boosted = CachedChannelData().withUpdatedBoostsToUnrestrict(2).withUpdatedAppliedBoosts(2)
        XCTAssertEqual(check(channel(defaultBans: [.banSendVoice, .banSendMedia]), boosted), .allowed)
        XCTAssertEqual(check(channel(defaultBans: [.banSendVoice]), boosted.withUpdatedAppliedBoosts(1)), .restricted)
        XCTAssertEqual(check(channel(defaultBans: [.banSendVoice]), boosted.withUpdatedBoostsToUnrestrict(0)), .restricted)
        XCTAssertEqual(check(channel(bans: [.banReadMessages]), boosted), .restricted)
        XCTAssertEqual(check(channel(participation: .left), boosted), .restricted)
        XCTAssertEqual(check(channel(), boosted.withUpdatedIsNotAccessible(true)), .restricted)
        XCTAssertEqual(check(channel(groupFlags: [.slowModeEnabled]),
            boosted.withUpdatedSlowModeTimeout(30), pending: true), .slowMode(until: nil))
        XCTAssertEqual(check(channel(fee: StarsAmount(value: 1, nanos: 0)), boosted), .paid)
    }
}
