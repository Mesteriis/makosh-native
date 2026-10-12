import Foundation
import Postbox
import TelegramCore

public enum TelegramPeerMemberCategory: String, CaseIterable, Identifiable, Sendable {
    case members, administrators, restricted, removed
    public var id: String { rawValue }
}

public struct TelegramPeerMember: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case member, administrator, creator, restricted, removed }
    public let id: Int64
    public let title: String
    public let role: Role
    public let adminRights: Int32
    public let bannedRights: Int32
    public let untilDate: Int32
    public let rank: String?
    public let editable: Bool
}

public struct TelegramPeerManagementSnapshot: Equatable, Sendable {
    public let accountID: Int64
    public let peerID: Int64
    public let title: String
    public let about: String?
    public let basicGroup: Bool
    public let canEditInfo: Bool
    public let canViewMembers: Bool
    public let canViewAdministrators: Bool
    public let canRestrict: Bool
    public let canPromote: Bool
    public let grantableRights: Int32
    public let defaultBannedRights: Int32?
    public init(accountID: Int64, peerID: Int64, title: String, about: String?, basicGroup: Bool,
        canEditInfo: Bool, canViewMembers: Bool, canViewAdministrators: Bool, canRestrict: Bool,
        canPromote: Bool, grantableRights: Int32, defaultBannedRights: Int32? = nil) {
        self.accountID = accountID; self.peerID = peerID; self.title = title; self.about = about; self.basicGroup = basicGroup
        self.canEditInfo = canEditInfo; self.canViewMembers = canViewMembers; self.canViewAdministrators = canViewAdministrators
        self.canRestrict = canRestrict; self.canPromote = canPromote; self.grantableRights = grantableRights; self.defaultBannedRights = defaultBannedRights
    }
}

public enum TelegramPeerChange: Equatable, Sendable {
    case permissions(previous: Int32, value: Int32)
    case title(previous: String, value: String)
    case about(previous: String?, value: String)
    case administrator(member: TelegramPeerMember, rights: Int32, rank: String)
    case restriction(member: TelegramPeerMember, rights: Int32, untilDate: Int32)
}

func telegramPeerManagement(peer: Peer?, cachedData: CachedPeerData?, accountID: Int64) -> TelegramPeerManagementSnapshot? {
    if let group = peer as? TelegramGroup, let cache = cachedData as? CachedGroupData,
       group.id.namespace == Namespaces.Peer.CloudGroup, group.membership == .Member,
       !group.flags.contains(.deactivated), group.migrationReference == nil {
        let privileged: Bool
        switch group.role { case .creator, .admin: privileged = true; case .member: privileged = false }
        let creator: Bool
        if case .creator = group.role { creator = true } else { creator = false }
        return .init(accountID: accountID, peerID: group.id.toInt64(), title: group.title, about: cache.about,
            basicGroup: true, canEditInfo: privileged || !group.hasBannedPermission(.banChangeInfo),
            canViewMembers: true, canViewAdministrators: true, canRestrict: privileged, canPromote: creator, grantableRights: creator ? 1 : 0, defaultBannedRights: group.defaultBannedRights?.flags.rawValue ?? 0)
    }
    guard let channel = peer as? TelegramChannel, let cache = cachedData as? CachedChannelData,
          channel.id.namespace == Namespaces.Peer.CloudChannel, channel.accessHash != nil,
          channel.participationStatus == .member, !cache.isNotAccessible,
          !channel.flags.contains(.isMonoforum) else { return nil }
    let creator = channel.flags.contains(.isCreator)
    let privileged = creator || channel.adminRights != nil
    let broadcast: Bool
    switch channel.info { case .broadcast: broadcast = true; case .group: broadcast = false }
    let possible = TelegramChatAdminRightsFlags.peerSpecific(peer: EnginePeer(channel))
    let grantable = creator ? possible : (channel.adminRights?.rights ?? []).intersection(possible)
    return .init(accountID: accountID, peerID: channel.id.toInt64(), title: channel.title, about: cache.about,
        basicGroup: false, canEditInfo: channel.hasPermission(.changeInfo),
        canViewMembers: privileged || (!broadcast && cache.flags.contains(.canDisplayParticipants)), canViewAdministrators: privileged || !broadcast,
        canRestrict: privileged && channel.hasPermission(.banMembers),
        canPromote: creator || channel.adminRights?.rights.contains(.canAddAdmins) == true,
        grantableRights: grantable.rawValue, defaultBannedRights: broadcast ? nil : channel.defaultBannedRights?.flags.rawValue ?? 0)
}

extension TelegramPeerManagementSnapshot {
    func permits(_ change: TelegramPeerChange) -> Bool {
        switch change {
        case let .permissions(previous, value):
            return canRestrict && defaultBannedRights == previous && value != previous && value >= 0
                && value & ~(telegramPeerSupportedBans.subtracting(.banReadMessages).rawValue) == 0
        case let .title(previous, value):
            return canEditInfo && previous == title && value.utf16.count <= 255
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value != previous
        case let .about(previous, value):
            return canEditInfo && previous == about && value.utf16.count <= 255 && value != (previous ?? "")
        case let .administrator(member, rights, rank):
            guard telegramManagementPeerID(member.id)?.namespace == Namespaces.Peer.CloudUser else { return false }
            if basicGroup { return canPromote && member.id != accountID && member.editable && member.role != .creator && (rights == 0 || rights == 1) && rank.isEmpty }
            return canPromote && member.id != accountID && member.editable
                && member.role != .creator && member.role != .removed && member.role != .restricted
                && rights >= 0 && rights & ~grantableRights == 0 && rank.utf16.count <= 16
        case let .restriction(member, rights, untilDate):
            guard telegramManagementPeerID(member.id)?.namespace == Namespaces.Peer.CloudUser,
                  untilDate == Int32.max || telegramPeerRestrictionExpiration(Date(timeIntervalSince1970: Double(untilDate))) != nil else { return false }
            if basicGroup { return canRestrict && member.id != accountID && member.editable && member.role == .member && rights == TelegramChatBannedRightsFlags.banReadMessages.rawValue && untilDate == Int32.max }
            return canRestrict && member.id != accountID && member.editable
                && member.role != .creator && member.role != .administrator && rights >= 0
                && rights & ~telegramPeerSupportedBans.rawValue == 0 && untilDate >= 0
        }
    }
    func permits(_ category: TelegramPeerMemberCategory) -> Bool {
        switch category {
        case .members: canViewMembers
        case .administrators: canViewAdministrators
        case .restricted, .removed: canRestrict && !basicGroup
        }
    }
}

var telegramPeerSupportedBans: TelegramChatBannedRightsFlags { [
    .banReadMessages, .banSendStickers, .banSendGifs, .banSendGames,
    .banSendInline, .banEmbedLinks, .banSendPolls, .banChangeInfo, .banAddMembers,
    .banPinMessages, .banManageTopics, .banSendPhotos, .banSendVideos, .banSendInstantVideos,
    .banSendMusic, .banSendVoice, .banSendFiles, .banSendText
] }

func telegramManagementPeerID(_ raw: Int64) -> PeerId? {
    guard UInt64(bitPattern: raw) >> 59 == 0 else { return nil }
    let id = PeerId(raw)
    guard [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(id.namespace),
          id.id._internalGetInt64Value() > 0 else { return nil }
    return id
}

func telegramPeerManagementRPCError(code: Int32) -> TelegramPeerManagementError { (400..<500).contains(code) ? .failed : .uncertain }

func telegramPeerAdminWireFlags(_ rights: Int32) -> Int32 { rights == 0 ? 0 : rights | (1 << 12) }
func telegramPeerBannedWireFlags(_ rights: Int32) -> Int32 { rights & ~TelegramChatBannedRightsFlags.banSendMedia.rawValue & ~(1 << 1) }

/// Telegram treats dates outside its finite window as forever. Leave a margin
/// for the bounded request deadline; only the explicit Int32.max choice is permanent.
public func telegramPeerRestrictionExpiration(_ date: Date, now: Date = Date()) -> Int32? {
    let seconds = date.timeIntervalSince1970, interval = date.timeIntervalSince(now)
    guard seconds.isFinite, interval >= 60, interval <= 365 * 86400,
          seconds > 0, seconds < Double(Int32.max) else { return nil }
    return Int32(exactly: Int64(seconds.rounded(.down)))
}
