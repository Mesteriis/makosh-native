import Foundation
import Postbox
import TelegramCore
import TelegramApi
import SwiftSignalKit

func telegramPeerMember(_ participant: GroupParticipant, peer: Peer) -> TelegramPeerMember {
    let role: TelegramPeerMember.Role
    switch participant { case .creator: role = .creator; case .admin: role = .administrator; case .member: role = .member }
    return .init(id: peer.id.toInt64(), title: telegramPeerTitle(peer), role: role, adminRights: role == .administrator ? 1 : 0,
        bannedRights: 0, untilDate: 0, rank: nil, editable: role != .creator)
}

func telegramPeerMember(_ participant: ChannelParticipant, peer: Peer, owner: Bool) -> TelegramPeerMember {
    let role: TelegramPeerMember.Role, admin: Int32, bans: Int32, until: Int32, editable: Bool
    switch participant {
    case .creator:
        role = .creator; admin = 0; bans = 0; until = 0; editable = false
    case let .member(_, _, info, ban, _, _):
        role = info != nil ? .administrator : (ban?.rights.flags.contains(.banReadMessages) == true ? .removed : (ban == nil ? .member : .restricted))
        admin = info?.rights.rights.rawValue ?? 0; bans = ban?.rights.flags.rawValue ?? 0
        until = ban?.rights.untilDate ?? 0; editable = info.map { owner || $0.canBeEditedByAccountPeer } ?? true
    }
    return .init(id: peer.id.toInt64(), title: telegramPeerTitle(peer), role: role, adminRights: admin,
        bannedRights: bans, untilDate: until, rank: participant.rank, editable: editable)
}

/// Re-read peer/cache after the participant RPC. No old UI permission snapshot
/// authorizes a write. The server remains the final authority for concurrent edits.
func telegramAdmitPeerChange(postbox: Postbox, accountID: Int64, peerID: PeerId, change: TelegramPeerChange,
    fetchMember: @escaping (PeerId) -> Signal<ChannelParticipant?, NoError>,
    perform: @escaping (Peer, Peer?, TelegramPeerChange) -> Signal<Void, TelegramPeerManagementError>) -> Signal<Void, TelegramPeerManagementError> {
    let expected: TelegramPeerMember?
    switch change {
    case let .administrator(member, _, _), let .restriction(member, _, _): expected = member
    default: expected = nil
    }
    guard expected.map({ telegramManagementPeerID($0.id)?.namespace == Namespaces.Peer.CloudUser }) ?? true else { return .fail(.changed) }
    let member: Signal<ChannelParticipant?, NoError> = peerID.namespace == Namespaces.Peer.CloudGroup ? .single(nil) : expected.map { fetchMember(PeerId($0.id)) } ?? .single(nil)
    return member |> castError(TelegramPeerManagementError.self) |> mapToSignal { participant in
        postbox.transaction { transaction -> Signal<Void, TelegramPeerManagementError> in
            guard let peer = transaction.getPeer(peerID), let snapshot = telegramPeerManagement(peer: peer, cachedData: transaction.getPeerCachedData(peerId: peerID), accountID: accountID),
                  snapshot.permits(change) else { return .fail(.changed) }
            var target: Peer?
            if let expected {
                let targetID = PeerId(expected.id)
                guard let memberPeer = transaction.getPeer(targetID) else { return .fail(.changed) }
                let current: TelegramPeerMember
                if snapshot.basicGroup {
                    guard let participant = (transaction.getPeerCachedData(peerId: peerID) as? CachedGroupData)?.participants?.participants.first(where: { $0.peerId == targetID }) else { return .fail(.changed) }
                    current = telegramPeerMember(participant, peer: memberPeer)
                } else {
                    guard let participant, participant.peerId == targetID else { return .fail(.changed) }
                    current = telegramPeerMember(participant, peer: memberPeer, owner: (peer as? TelegramChannel)?.flags.contains(.isCreator) == true)
                }
                guard current == expected else { return .fail(.changed) }
                target = memberPeer
            }
            return perform(peer, target, change)
        } |> castError(TelegramPeerManagementError.self) |> switchToLatest
    }
}

func telegramAcknowledgeBasicAdministrator(postbox: Postbox, peerID: PeerId, member: TelegramPeerMember, rights: Int32) -> Signal<Void, NoError> {
    postbox.transaction { transaction in
        guard rights == 0 || rights == 1, let memberID = telegramManagementPeerID(member.id), let peer = transaction.getPeer(memberID) else { return }
        transaction.updatePeerCachedData(peerIds: [peerID], update: { _, data in
            guard let cache = data as? CachedGroupData, let participants = cache.participants,
                  let index = participants.participants.firstIndex(where: { $0.peerId == memberID }),
                  telegramPeerMember(participants.participants[index], peer: peer) == member else { return data }
            var updated = participants.participants
            switch updated[index] {
            case let .member(id, invitedBy, invitedAt), let .admin(id, invitedBy, invitedAt):
                updated[index] = rights == 0 ? .member(id: id, invitedBy: invitedBy, invitedAt: invitedAt) : .admin(id: id, invitedBy: invitedBy, invitedAt: invitedAt)
            case .creator: return data
            }
            return cache.withUpdatedParticipants(.init(participants: updated, version: participants.version))
        })
    }
}

private final class PeerManagementBackend {
    let account: Account
    init(account: Account) { self.account = account }
    func load(peerID: PeerId, category: TelegramPeerMemberCategory?, query: String, offset: Int32) -> Signal<TelegramPeerMemberPage, TelegramPeerManagementError> {
        let account = account
        return account.postbox.peerView(id: peerID) |> take(1) |> castError(TelegramPeerManagementError.self) |> mapToSignal { view in
            guard let peer = view.peers[peerID], let snapshot = telegramPeerManagement(peer: peer, cachedData: view.cachedData, accountID: account.peerId.toInt64()) else { return .fail(.unavailable) }
            guard let category else { return .single(.init(snapshot: snapshot, members: [], nextOffset: nil)) }
            guard snapshot.permits(category) else { return .fail(.unavailable) }
            if let cache = view.cachedData as? CachedGroupData {
                guard let participants = cache.participants?.participants, offset == 0 else { return .fail(.unavailable) }
                var members: [TelegramPeerMember] = []
                for participant in participants {
                    guard let memberPeer = view.peers[participant.peerId] else { return .fail(.unavailable) }
                    let member = telegramPeerMember(participant, peer: memberPeer)
                    if (category == .members || member.role != .member) && (query.isEmpty || member.title.localizedCaseInsensitiveContains(query)) { members.append(member) }
                }
                return .single(.init(snapshot: snapshot, members: members, nextOffset: nil))
            }
            let filter: ChannelMembersCategoryFilter = query.isEmpty ? .all : .search(query)
            let native: ChannelMembersCategory
            switch category {
            case .members: native = .recent(filter)
            case .administrators: native = .admins
            case .restricted: native = .restricted(filter)
            case .removed: native = .banned(filter)
            }
            return TelegramEngine(account: account).peers.channelMembers(peerId: peerID, category: native, offset: offset, limit: 64, hash: 0)
                |> castError(TelegramPeerManagementError.self) |> mapToSignal { values in
                    guard let values else { return .fail(.failed) }
                    let owner = (peer as? TelegramChannel)?.flags.contains(.isCreator) == true
                    let mapped = values.map { telegramPeerMember($0.participant, peer: $0.peer, owner: owner) }
                    let visible = category == .administrators && !query.isEmpty ? mapped.filter { $0.title.localizedCaseInsensitiveContains(query) } : mapped
                    let next = Int64(offset) + Int64(values.count)
                    return .single(.init(snapshot: snapshot, members: visible, nextOffset: values.count == 64 ? Int32(exactly: next) : nil))
                }
        }
    }
    func apply(peerID: PeerId, change: TelegramPeerChange) -> Signal<Void, TelegramPeerManagementError> {
        let account = account
        return telegramAdmitPeerChange(postbox: account.postbox, accountID: account.peerId.toInt64(), peerID: peerID, change: change,
            fetchMember: { TelegramEngine(account: account).peers.fetchChannelParticipant(peerId: peerID, participantId: $0) },
            perform: { [self] peer, target, change in request(peer: peer, target: target, change: change) })
    }
    private func request(peer: Peer, target: Peer?, change: TelegramPeerChange) -> Signal<Void, TelegramPeerManagementError> {
        let account = account
        let input: Api.InputPeer
        let channel: Api.InputChannel?
        if let peer = peer as? TelegramChannel, let hash = peer.accessHash {
            channel = .inputChannel(channelId: peer.id.id._internalGetInt64Value(), accessHash: hash.value)
            input = .inputPeerChannel(channelId: peer.id.id._internalGetInt64Value(), accessHash: hash.value)
        } else if let peer = peer as? TelegramGroup {
            channel = nil; input = .inputPeerChat(chatId: peer.id.id._internalGetInt64Value())
        } else { return .fail(.unavailable) }
        let updates: Signal<Api.Updates, TelegramPeerManagementError>
        switch change {
        case let .permissions(_, value):
            updates = account.network.request(Api.functions.messages.editChatDefaultBannedRights(peer: input,
                bannedRights: .chatBannedRights(flags: telegramPeerBannedWireFlags(value), untilDate: Int32.max)), automaticFloodWait: false)
                |> mapError { telegramPeerManagementRPCError(code: $0.errorCode) }
        case let .title(_, value):
            if let channel {
                updates = account.network.request(Api.functions.channels.editTitle(channel: channel, title: value), automaticFloodWait: false) |> mapError { telegramPeerManagementRPCError(code: $0.errorCode) }
            } else {
                updates = account.network.request(Api.functions.messages.editChatTitle(chatId: peer.id.id._internalGetInt64Value(), title: value), automaticFloodWait: false) |> mapError { telegramPeerManagementRPCError(code: $0.errorCode) }
            }
        case let .about(previous, value):
            return account.network.request(Api.functions.messages.editChatAbout(peer: input, about: value), automaticFloodWait: false)
                |> mapError { telegramPeerManagementRPCError(code: $0.errorCode) } |> mapToSignal { result in
                    guard case .boolTrue = result else { return .fail(.failed) }
                    return account.postbox.transaction { transaction -> Void in
                        transaction.updatePeerCachedData(peerIds: [peer.id], update: { _, cache in
                            if let cache = cache as? CachedGroupData, cache.about == previous { return cache.withUpdatedAbout(value.isEmpty ? nil : value) }
                            if let cache = cache as? CachedChannelData, cache.about == previous { return cache.withUpdatedAbout(value.isEmpty ? nil : value) }
                            return cache
                        })
                    } |> castError(TelegramPeerManagementError.self)
                }
        case let .administrator(member, rights, rank):
            guard let user = target as? TelegramUser, user.id.namespace == Namespaces.Peer.CloudUser, let hash = user.accessHash else { return .fail(.unavailable) }
            if channel == nil {
                return account.network.request(Api.functions.messages.editChatAdmin(chatId: peer.id.id._internalGetInt64Value(),
                    userId: .inputUser(userId: user.id.id._internalGetInt64Value(), accessHash: hash.value), isAdmin: rights == 0 ? .boolFalse : .boolTrue), automaticFloodWait: false)
                    |> mapError { telegramPeerManagementRPCError(code: $0.errorCode) } |> mapToSignal { result in
                        guard case .boolTrue = result else { return .fail(.failed) }
                        return telegramAcknowledgeBasicAdministrator(postbox: account.postbox, peerID: peer.id, member: member, rights: rights)
                            |> castError(TelegramPeerManagementError.self) |> map {
                                account.viewTracker.forceUpdateCachedPeerData(peerId: peer.id)
                            }
                    }
            }
            guard let channel else { return .fail(.unavailable) }
            updates = account.network.request(Api.functions.channels.editAdmin(channel: channel,
                userId: .inputUser(userId: user.id.id._internalGetInt64Value(), accessHash: hash.value),
                adminRights: .chatAdminRights(flags: telegramPeerAdminWireFlags(rights)), rank: rank), automaticFloodWait: false) |> mapError { telegramPeerManagementRPCError(code: $0.errorCode) }
        case let .restriction(_, rights, until):
            guard let user = target as? TelegramUser, user.id.namespace == Namespaces.Peer.CloudUser, let hash = user.accessHash else { return .fail(.unavailable) }
            if let channel {
                updates = account.network.request(Api.functions.channels.editBanned(channel: channel,
                participant: .inputPeerUser(userId: user.id.id._internalGetInt64Value(), accessHash: hash.value),
                bannedRights: .chatBannedRights(flags: telegramPeerBannedWireFlags(rights), untilDate: rights == 0 ? 0 : until)), automaticFloodWait: false) |> mapError { telegramPeerManagementRPCError(code: $0.errorCode) }
            } else {
                updates = account.network.request(Api.functions.messages.deleteChatUser(flags: 0, chatId: peer.id.id._internalGetInt64Value(),
                    userId: .inputUser(userId: user.id.id._internalGetInt64Value(), accessHash: hash.value)), automaticFloodWait: false) |> mapError { telegramPeerManagementRPCError(code: $0.errorCode) }
            }
        }
        return updates |> map {
            account.stateManager.addUpdates($0)
            account.viewTracker.forceUpdateCachedPeerData(peerId: peer.id)
        }
    }
}

@MainActor final class TelegramEnginePeerManagementProvider: TelegramPeerManagementProvider {
    let accountID: Int64
    private let backend: PeerManagementBackend
    init(account: Account) { accountID = account.peerId.toInt64(); backend = .init(account: account) }
    func load(peerID: Int64, category: TelegramPeerMemberCategory?, query: String, offset: Int32,
        receive: @escaping @MainActor (Result<TelegramPeerMemberPage, TelegramPeerManagementError>) -> Void) -> any TelegramPeerManagementRequest {
        let request = PeerManagementRequest()
        guard let id = telegramManagementPeerID(peerID), id.namespace != Namespaces.Peer.CloudUser, offset >= 0, query.utf16.count <= 255 else { receive(.failure(.unavailable)); return request }
        request.disposable.set((backend.load(peerID: id, category: category, query: query, offset: offset) |> deliverOnMainQueue).start(
            next: { value in MainActor.assumeIsolated { receive(.success(value)) } },
            error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
    func apply(peerID: Int64, change: TelegramPeerChange,
        receive: @escaping @MainActor (Result<Void, TelegramPeerManagementError>) -> Void) -> any TelegramPeerManagementRequest {
        let request = PeerManagementRequest()
        guard let id = telegramManagementPeerID(peerID), id.namespace != Namespaces.Peer.CloudUser else { receive(.failure(.unavailable)); return request }
        request.disposable.set((backend.apply(peerID: id, change: change) |> deliverOnMainQueue).start(
            error: { error in MainActor.assumeIsolated { receive(.failure(error)) } },
            completed: { MainActor.assumeIsolated { receive(.success(())) } }))
        return request
    }
}
@MainActor private final class PeerManagementRequest: TelegramPeerManagementRequest {
    let disposable = MetaDisposable()
    func cancel() { disposable.dispose() }
    isolated deinit { disposable.dispose() }
}
