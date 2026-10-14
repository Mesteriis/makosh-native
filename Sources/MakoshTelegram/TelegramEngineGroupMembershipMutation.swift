import Foundation
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit

struct TelegramPreparedGroupChange {
    let basis: TelegramNativeGroupBasis
    let user: Api.InputUser?
}
// Only this exact Telegram RPC error is an authoritative negative member result.
// Other errors (including transport failure) never authorize an invitation.
private func groupChannelMembership(account: Account, basis: TelegramNativeGroupBasis, user: Api.InputUser, userID: Int64) -> Signal<Bool, TelegramGroupMembershipError> {
    if basis.snapshot.basic {
        guard let id = telegramManagementPeerID(userID), id.namespace == Namespaces.Peer.CloudUser, let members = basis.full.members else { return .fail(.unavailable) }
        return .single(members.contains(id))
    }
    guard let channel = basis.full.peer as? TelegramChannel, case let .personal(hash) = channel.accessHash,
          case let .inputUser(rawID, userHash) = user, rawID == PeerId(userID).id._internalGetInt64Value() else { return .fail(.unavailable) }
    return account.network.request(Api.functions.channels.getParticipant(
        channel: .inputChannel(channelId: channel.id.id._internalGetInt64Value(), accessHash: hash),
        participant: .inputPeerUser(userId: rawID, accessHash: userHash)), automaticFloodWait: false)
        |> map { response -> Bool? in
            switch response { case let .channelParticipant(value, _, _): return telegramGroupParticipantMembership(value, userID: rawID) }
        } |> `catch` { error -> Signal<Bool?, TelegramGroupMembershipError> in
            if error.errorDescription == "USER_NOT_PARTICIPANT" { return .single(false) }; return .fail(.failed)
        } |> mapToSignal { value in
            guard let value else { return .fail(.unavailable) }; return .single(value)
        }
}
private func groupMutationUserInput(account: Account, id: Int64) -> Signal<Api.InputUser, TelegramGroupMembershipError> {
    account.postbox.transaction { transaction -> Api.InputUser? in
        guard let nativeID = telegramManagementPeerID(id), nativeID.namespace == Namespaces.Peer.CloudUser,
              let user = transaction.getPeer(nativeID) as? TelegramUser, !user.isDeleted,
              case let .personal(hash) = user.accessHash, hash != 0 else { return nil }
        return .inputUser(userId: nativeID.id._internalGetInt64Value(), accessHash: hash)
    } |> castError(TelegramGroupMembershipError.self) |> mapToSignal { value in
        guard let value else { return .fail(.unavailable) }; return .single(value)
    }
}
private func groupFreshUser(account: Account, target: TelegramDiscoveredPeer) -> Signal<Api.InputUser, TelegramGroupMembershipError> {
    guard target.isValid, PeerId(target.id).namespace == Namespaces.Peer.CloudUser, target.id != account.peerId.toInt64() else { return .fail(.unavailable) }
    return groupMutationUserInput(account: account, id: target.id) |> mapToSignal { input in
        account.network.request(Api.functions.users.getUsers(id: [input]), automaticFloodWait: false)
            |> mapError { _ in TelegramGroupMembershipError.failed } |> mapToSignal { users in
                account.postbox.transaction { transaction -> Api.InputUser? in
                    guard users.count == 1 else { return nil }
                    switch users[0] {
                    case let .user(flags, _, id, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _):
                        guard flags & (1 << 20) == 0, id == PeerId(target.id).id._internalGetInt64Value() else { return nil }
                    case .userEmpty: return nil
                    }
                    let id = PeerId(target.id)
                    guard let directory = makoshGroupPeerDirectory(transaction: transaction, chats: [], users: users, requiredIds: [id]),
                          let peer = directory.peers[id] as? TelegramUser, !peer.isDeleted, peer.botInfo == nil,
                          telegramDiscoveredPeer(peer, accountID: account.peerId.toInt64()) == target,
                          case let .personal(hash) = peer.accessHash, hash != 0 else { return nil }
                    makoshCommitGroupPeerDirectory(transaction: transaction, accountPeerId: account.peerId, directory: directory)
                    return .inputUser(userId: id.id._internalGetInt64Value(), accessHash: hash)
                } |> castError(TelegramGroupMembershipError.self) |> mapToSignal { value in
                    guard let value else { return .fail(.changed) }; return .single(value)
                }
            }
    }
}
private func groupFreshLink(account: Account, basis: TelegramNativeGroupBasis, target: TelegramGroupInviteLink) -> Signal<TelegramGroupInviteLink, TelegramGroupMembershipError> {
    guard let link = target.link, target.isValid else { return .fail(.unavailable) }
    return account.network.request(Api.functions.messages.getExportedChatInvite(peer: basis.input, link: link), automaticFloodWait: false)
        |> mapError { _ in TelegramGroupMembershipError.failed } |> mapToSignal { response in
            guard case let .exportedChatInvite(invite, _) = response, let value = telegramGroupInviteLink(invite, origin: target.origin),
                  value.link == target.link, value.adminID == target.adminID else { return .fail(.changed) }
            return .single(value)
        }
}
private func groupFindRequest(account: Account, basis: TelegramNativeGroupBasis, targetID: Int64,
    cursor: TelegramGroupMembershipCursor? = nil, seen: Set<Int64> = []) -> Signal<TelegramGroupJoinRequest?, TelegramGroupMembershipError> {
    telegramFindGroupRequest(snapshot: basis.snapshot, targetID: targetID, cursor: cursor, seen: seen) { offset in
        telegramNativeGroupPage(account: account, basis: basis, page: .requests, ownerID: nil, query: "", cursor: offset)
    }
}
func telegramFindGroupRequest(snapshot: TelegramGroupMembershipSnapshot, targetID: Int64, cursor: TelegramGroupMembershipCursor? = nil,
    seen: Set<Int64> = [], load: @escaping (TelegramGroupMembershipCursor?) -> Signal<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Signal<TelegramGroupJoinRequest?, TelegramGroupMembershipError> {
    guard snapshot.isValid, snapshot.canRequests, telegramManagementPeerID(targetID)?.namespace == Namespaces.Peer.CloudUser,
          targetID != snapshot.accountID, seen.count < 10_000 else { return .fail(.unavailable) }
    return load(cursor) |> mapToSignal { page in
        let ids = Set(page.requests.map(\.id))
        guard page.snapshot == snapshot, page.links.isEmpty, page.events.isEmpty, page.requests.count <= 50,
              page.requests.allSatisfy({ $0.isValid && $0.origin == cursor && $0.id != snapshot.accountID }),
              ids.count == page.requests.count, seen.isDisjoint(with: ids), seen.count + ids.count <= 10_000 else { return .fail(.unavailable) }
        let accumulated = seen.union(ids)
        if let next = page.next {
            guard case let .requests(date, userID, count) = next, let last = page.requests.last,
                  date == last.date, userID == last.id, count == accumulated.count else { return .fail(.unavailable) }
            if let cursor {
                guard case let .requests(previousDate, previousID, previousCount) = cursor,
                      date <= previousDate, userID != previousID, previousCount == seen.count else { return .fail(.unavailable) }
            }
        }
        if let row = page.requests.first(where: { $0.id == targetID }) { return .single(row) }
        guard let next = page.next else { return .single(nil) }
        return telegramFindGroupRequest(snapshot: snapshot, targetID: targetID, cursor: next, seen: accumulated, load: load)
    }
}
private func groupSameRequest(_ first: TelegramGroupJoinRequest, _ second: TelegramGroupJoinRequest) -> Bool {
    first.id == second.id && first.title == second.title && first.username == second.username && first.date == second.date && first.about == second.about
}
func telegramPrepareGroupChange(account: Account, basis: TelegramGroupMembershipSnapshot, change: TelegramGroupMembershipChange) -> Signal<TelegramPreparedGroupChange, TelegramGroupMembershipError> {
    guard basis.isValid, basis.accountID == account.peerId.toInt64() else { return .fail(.unavailable) }
    return telegramNativeGroupBasis(account: account, peerID: basis.peerID) |> mapToSignal { fresh in
        guard fresh.snapshot == basis else { return .fail(.changed) }
        let target: Signal<Api.InputUser?, TelegramGroupMembershipError>
        switch change {
        case let .invite(peer):
            guard basis.canInvite else { return .fail(.changed) }
            target = groupFreshUser(account: account, target: peer) |> mapToSignal { user in
                groupChannelMembership(account: account, basis: fresh, user: user, userID: peer.id) |> mapToSignal { member in
                    guard !member else { return .fail(.changed) }; return .single(user)
                }
            }
        case let .create(draft):
            guard basis.canManageLinks, draft.isValid() else { return .fail(.changed) }; target = .single(nil)
        case let .revoke(link):
            guard basis.canManageLinks, !link.revoked, link.adminID == basis.accountID || basis.isCreator else { return .fail(.changed) }
            target = groupFreshLink(account: account, basis: fresh, target: link) |> mapToSignal { current in
                guard current == link else { return .fail(.changed) }; return .single(nil)
            }
        case let .request(row, _):
            guard basis.canRequests, row.isValid, row.id != basis.accountID else { return .fail(.changed) }
            target = groupFindRequest(account: account, basis: fresh, targetID: row.id) |> mapToSignal { value in
                guard let value, groupSameRequest(value, row) else { return .fail(.changed) }
                return groupMutationUserInput(account: account, id: row.id) |> map { Optional($0) }
            }
        }
        return target |> mapToSignal { user in
            telegramNativeGroupBasis(account: account, peerID: basis.peerID) |> mapToSignal { current in
                guard current.snapshot == basis else { return .fail(.changed) }
                return .single(.init(basis: current, user: user))
            }
        }
    }
}
func telegramCommitGroupChange(account: Account, basis prepared: TelegramPreparedGroupChange,
    change: TelegramGroupMembershipChange) -> Signal<TelegramGroupMembershipReceipt, TelegramGroupMembershipError> {
    let basis = prepared.basis
    func receipt(_ result: TelegramGroupMembershipReceipt.Result) -> TelegramGroupMembershipReceipt {
        .init(accountID: basis.snapshot.accountID, peerID: basis.snapshot.peerID, result: result)
    }
    switch change {
    case let .invite(peer):
        guard let user = prepared.user else { return .fail(.uncertain) }
        let request: Signal<Api.messages.InvitedUsers, TelegramGroupMembershipError>
        if basis.snapshot.basic {
            request = account.network.request(Api.functions.messages.addChatUser(chatId: PeerId(basis.snapshot.peerID).id._internalGetInt64Value(), userId: user, fwdLimit: 0), automaticFloodWait: false) |> mapError { _ in .uncertain }
        } else {
            guard let channel = basis.full.peer as? TelegramChannel, case let .personal(hash) = channel.accessHash else { return .fail(.uncertain) }
            request = account.network.request(Api.functions.channels.inviteToChannel(channel: .inputChannel(channelId: channel.id.id._internalGetInt64Value(), accessHash: hash), users: [user]), automaticFloodWait: false) |> mapError { _ in .uncertain }
        }
        return request |> mapToSignal { response in
            switch telegramGroupInvitationAck(response, userID: PeerId(peer.id).id._internalGetInt64Value()) {
            case let .failure(error): return .fail(error)
            case let .success(updates): account.stateManager.addUpdates(updates)
            }
            return telegramNativeGroupBasis(account: account, peerID: basis.snapshot.peerID) |> mapToSignal { current in
                groupChannelMembership(account: account, basis: current, user: user, userID: peer.id) |> mapToSignal { member in
                    guard member else { return .fail(.uncertain) }; return .single(receipt(.invited(peer.id)))
                }
            }
        }
    case let .create(draft):
        guard let rpc = telegramGroupCreateInviteRPC(peer: basis.input, draft: draft) else { return .fail(.uncertain) }
        return account.network.request(rpc, automaticFloodWait: false) |> mapError { _ in TelegramGroupMembershipError.uncertain } |> mapToSignal { response in
            guard let link = telegramGroupInviteLink(response), receipt(.created(link)).matches(change, basis: basis.snapshot) else { return .fail(.uncertain) }
            return groupFreshLink(account: account, basis: basis, target: link) |> mapToSignal { current in
                guard receipt(.created(current)).matches(change, basis: basis.snapshot) else { return .fail(.uncertain) }; return .single(receipt(.created(current)))
            }
        }
    case let .revoke(link):
        guard let raw = link.link, let rpc = telegramGroupRevokeInviteRPC(peer: basis.input, link: raw) else { return .fail(.uncertain) }
        return account.network.request(rpc, automaticFloodWait: false) |> mapError { _ in TelegramGroupMembershipError.uncertain } |> mapToSignal { response in
            guard telegramGroupRevokeAck(response, expected: link) else { return .fail(.uncertain) }
            return groupFreshLink(account: account, basis: basis, target: link) |> mapToSignal { value in
                guard value.revoked else { return .fail(.uncertain) }; return .single(receipt(.revoked(raw)))
            }
        }
    case let .request(row, approve):
        guard let user = prepared.user else { return .fail(.uncertain) }
        return account.network.request(Api.functions.messages.hideChatJoinRequest(flags: approve ? 1 : 0, peer: basis.input, userId: user), automaticFloodWait: false)
            |> mapError { _ in TelegramGroupMembershipError.uncertain } |> mapToSignal { updates in
                account.stateManager.addUpdates(updates)
                return telegramNativeGroupBasis(account: account, peerID: basis.snapshot.peerID) |> mapToSignal { current in
                    groupFindRequest(account: account, basis: current, targetID: row.id) |> mapToSignal { remaining in
                        guard remaining == nil else { return .fail(.uncertain) }
                        return groupChannelMembership(account: account, basis: current, user: user, userID: row.id) |> mapToSignal { member in
                            guard member == approve else { return .fail(.uncertain) }; return .single(receipt(.processed(row.id, approve: approve)))
                        }
                    }
                }
            }
    }
}
