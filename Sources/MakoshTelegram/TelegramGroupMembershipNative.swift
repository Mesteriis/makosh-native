import Foundation
import Postbox
import TelegramCore
import TelegramApi

func telegramGroupMembershipSnapshot(peer: Peer, accountID: Int64) -> TelegramGroupMembershipSnapshot? {
    let basic: Bool, creator: Bool, invite: Bool, links: Bool, history: Bool
    if let group = peer as? TelegramGroup {
        guard group.id.namespace == Namespaces.Peer.CloudGroup, group.membership == .Member, !group.flags.contains(.deactivated), group.migrationReference == nil else { return nil }
        basic = true
        if case .creator = group.role { creator = true } else { creator = false }
        invite = !group.hasBannedPermission(.banAddMembers); links = creator; history = false
    } else if let channel = peer as? TelegramChannel {
        guard channel.id.namespace == Namespaces.Peer.CloudChannel, case let .personal(hash) = channel.accessHash, hash != 0,
              channel.participationStatus == .member, !channel.flags.contains(.isMonoforum) else { return nil }
        basic = false; creator = channel.flags.contains(.isCreator)
        links = creator || channel.adminRights?.rights.contains(.canInviteUsers) == true
        invite = links || channel.hasPermission(.inviteMembers); history = creator || channel.adminRights != nil
    } else { return nil }
    let value = TelegramGroupMembershipSnapshot(accountID: accountID, peerID: peer.id.toInt64(), title: telegramPeerTitle(peer),
        basic: basic, isCreator: creator, canInvite: invite, canManageLinks: links, canRequests: links, canHistory: history)
    return value.isValid ? value : nil
}
func telegramGroupInputPeer(_ peer: Peer) -> Api.InputPeer? {
    if let group = peer as? TelegramGroup { return .inputPeerChat(chatId: group.id.id._internalGetInt64Value()) }
    if let channel = peer as? TelegramChannel, case let .personal(hash) = channel.accessHash, hash != 0 {
        return .inputPeerChannel(channelId: channel.id.id._internalGetInt64Value(), accessHash: hash)
    }
    return nil
}
private func groupInputValid(_ peer: Api.InputPeer) -> Bool {
    switch peer { case let .inputPeerChat(id): return id > 0; case let .inputPeerChannel(id, hash): return id > 0 && hash != 0; default: return false }
}
func telegramGroupCreateInviteRPC(peer: Api.InputPeer, draft: TelegramGroupInviteDraft) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.ExportedChatInvite>)? {
    guard groupInputValid(peer), draft.isValid() else { return nil }
    let flags: Int32 = (draft.expireDate == nil ? 0 : 1) | (draft.usageLimit == nil ? 0 : 2)
        | (draft.requiresApproval ? 8 : 0) | (draft.normalizedTitle == nil ? 0 : 16)
    return Api.functions.messages.exportChatInvite(flags: flags, peer: peer, expireDate: draft.expireDate, usageLimit: draft.usageLimit,
        title: draft.normalizedTitle, subscriptionPricing: nil)
}
func telegramGroupRevokeInviteRPC(peer: Api.InputPeer, link: String) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.messages.ExportedChatInvite>)? {
    guard groupInputValid(peer), telegramValidGroupInviteURL(link) else { return nil }
    return Api.functions.messages.editExportedChatInvite(flags: 4, peer: peer, link: link, expireDate: nil, usageLimit: nil, requestNeeded: nil, title: nil)
}
func telegramGroupParticipantIsMember(_ value: Api.ChannelParticipant, userID: Int64) -> Bool {
    guard userID > 0 else { return false }
    switch value {
    case let .channelParticipant(_, id, _, _), let .channelParticipantAdmin(_, id, _, _, _, _, _),
         let .channelParticipantCreator(_, id, _, _), let .channelParticipantSelf(_, id, _, _, _): return id == userID
    case let .channelParticipantBanned(flags, peer, _, _, rights):
        guard case let .peerUser(id) = peer, id == userID, flags & 1 == 0 else { return false }
        switch rights { case let .chatBannedRights(flags, _): return flags & TelegramChatBannedRightsFlags.banReadMessages.rawValue == 0 }
    case .channelParticipantLeft: return false
    }
}
func telegramGroupParticipantMembership(_ value: Api.ChannelParticipant, userID: Int64) -> Bool? {
    guard userID > 0 else { return nil }
    let actual: Int64
    switch value {
    case let .channelParticipant(_, id, _, _), let .channelParticipantAdmin(_, id, _, _, _, _, _),
         let .channelParticipantCreator(_, id, _, _), let .channelParticipantSelf(_, id, _, _, _): actual = id
    case let .channelParticipantBanned(_, peer, _, _, _), let .channelParticipantLeft(peer):
        guard case let .peerUser(id) = peer else { return nil }; actual = id
    }
    guard actual == userID else { return nil }
    return telegramGroupParticipantIsMember(value, userID: userID)
}
func telegramGroupInviteLink(_ value: Api.ExportedChatInvite, origin: TelegramGroupMembershipCursor? = nil) -> TelegramGroupInviteLink? {
    let result: TelegramGroupInviteLink
    switch value {
    case let .chatInviteExported(flags, link, adminId, date, _, expireDate, usageLimit, usage, requested, _, title, pricing):
        result = .init(link: link, adminID: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(adminId)).toInt64(), date: date,
            title: title, expireDate: expireDate, usageLimit: usageLimit, usage: usage ?? 0, requested: requested ?? 0,
            requiresApproval: flags & 64 != 0, revoked: flags & 1 != 0, permanent: flags & 32 != 0, paid: pricing != nil, origin: origin)
    case .chatInvitePublicJoinRequests:
        result = .init(link: nil, adminID: 0, date: 0, title: nil, expireDate: nil, usageLimit: nil, usage: 0, requested: 0,
            requiresApproval: true, revoked: false, permanent: false, paid: false, origin: nil)
    }
    return result.isValid ? result : nil
}

func telegramGroupLinkPage(snapshot: TelegramGroupMembershipSnapshot, ownerID: Int64, result: Api.messages.ExportedChatInvites,
    revoked: Bool, cursor: TelegramGroupMembershipCursor?) -> TelegramGroupMembershipPage? {
    guard snapshot.isValid, snapshot.canManageLinks, ownerID == snapshot.accountID || snapshot.isCreator else { return nil }
    let seen: Int32
    if let cursor { guard case let .links(_, _, count) = cursor, count > 0 else { return nil }; seen = count } else { seen = 0 }
    switch result {
    case let .exportedChatInvites(count, invites, _):
        let links = invites.compactMap { telegramGroupInviteLink($0, origin: cursor) }
        guard invites.count <= 50, links.count == invites.count, Set(links.map(\.id)).count == links.count,
              count >= 0, Int64(count) >= Int64(seen) + Int64(links.count),
              links.allSatisfy({ $0.link == nil ? !revoked : $0.adminID == ownerID && $0.revoked == revoked }) else { return nil }
        var page = TelegramGroupMembershipPage(snapshot: snapshot, links: links)
        let loaded = Int64(seen) + Int64(links.count)
        if loaded < count {
            guard let last = links.last, let link = last.link, loaded <= Int32.max else { return nil }
            page.next = .links(date: last.date, link: link, seen: Int32(loaded))
        }
        return page
    }
}
func telegramGroupRequestPage(snapshot: TelegramGroupMembershipSnapshot, result: Api.messages.ChatInviteImporters,
    peers: [PeerId: Peer], cursor: TelegramGroupMembershipCursor?) -> TelegramGroupMembershipPage? {
    guard snapshot.isValid, snapshot.canRequests else { return nil }
    let seen: Int32
    if let cursor { guard case let .requests(_, _, count) = cursor, count > 0 else { return nil }; seen = count } else { seen = 0 }
    switch result {
    case let .chatInviteImporters(count, importers, _):
        guard importers.count <= 50, count >= 0, Int64(count) >= Int64(seen) + Int64(importers.count) else { return nil }
        var requests: [TelegramGroupJoinRequest] = []
        for importer in importers {
            switch importer {
            case let .chatInviteImporter(flags, userID, date, about, approvedBy):
                let id = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(userID))
                guard flags & 1 != 0, approvedBy == nil, let user = peers[id] as? TelegramUser, !user.isDeleted,
                      user.botInfo == nil, let discovered = telegramDiscoveredPeer(user, accountID: snapshot.accountID) else { return nil }
                let row = TelegramGroupJoinRequest(id: id.toInt64(), title: discovered.chat.title, username: discovered.username, date: date, about: about, origin: cursor)
                guard row.isValid, row.id != snapshot.accountID else { return nil }; requests.append(row)
            }
        }
        guard Set(requests.map(\.id)).count == requests.count else { return nil }
        var page = TelegramGroupMembershipPage(snapshot: snapshot, requests: requests)
        let loaded = Int64(seen) + Int64(requests.count)
        if loaded < count {
            guard let last = requests.last, loaded <= Int32.max else { return nil }
            page.next = .requests(date: last.date, userID: last.id, seen: Int32(loaded))
        }
        return page
    }
}
func telegramGroupInvitationAck(_ response: Api.messages.InvitedUsers, userID: Int64) -> Result<Api.Updates, TelegramGroupMembershipError> {
    guard userID > 0 else { return .failure(.uncertain) }
    switch response {
    case let .invitedUsers(updates, missing):
        if missing.isEmpty { return .success(updates) }
        guard missing.count == 1, case let .missingInvitee(_, id) = missing[0], id == userID else { return .failure(.uncertain) }
        return .failure(.privacyLimited)
    }
}
func telegramGroupRevokeAck(_ response: Api.messages.ExportedChatInvite, expected: TelegramGroupInviteLink) -> Bool {
    let original: Api.ExportedChatInvite
    switch response {
    case let .exportedChatInvite(invite, _): original = invite
    case let .exportedChatInviteReplaced(invite, replacement, _):
        guard let next = telegramGroupInviteLink(replacement), next.link != nil, next.link != expected.link,
              !next.revoked, next.adminID == expected.adminID else { return false }; original = invite
    }
    guard let value = telegramGroupInviteLink(original), value.link == expected.link, value.adminID == expected.adminID, value.revoked else { return false }
    return true
}
