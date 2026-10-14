# SPDX-License-Identifier: MIT
"""Own bounded peer/durable-observation bridge inside pinned TelegramCore."""
def group_membership_helper_source():
    return '''// Own Makosh MIT adapter; linked TelegramCore remains GPL-3.0-or-later.
import Foundation
import Postbox
import TelegramApi

public struct MakoshGroupFullPeer {
    public let peer: Peer
    public let members: Set<PeerId>?
}
public func makoshGroupFullPeer(_ result: Api.messages.ChatFull, peerId: PeerId) -> MakoshGroupFullPeer? {
    guard let photo = makoshAvatarChatPhotoResult(result, peerId: peerId) else { return nil }
    var members: Set<PeerId>?
    switch result {
    case let .chatFull(full, _, _):
        if case let .chatFull(_, id, _, participants, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = full {
            guard peerId.namespace == Namespaces.Peer.CloudGroup, id == peerId.id._internalGetInt64Value() else { return nil }
            if case let .chatParticipants(chatId, values, _) = participants {
                guard chatId == id, values.count <= 1000 else { return nil }
                let ids = values.map { GroupParticipant(apiParticipant: $0).peerId }
                guard ids.allSatisfy({ $0.namespace == Namespaces.Peer.CloudUser && $0.id._internalGetInt64Value() > 0 }), Set(ids).count == ids.count else { return nil }
                members = Set(ids)
            }
        }
    }
    return MakoshGroupFullPeer(peer: photo.peer, members: members)
}
public struct MakoshGroupPeerDirectory {
    public let peers: [PeerId: Peer]
    fileprivate let accumulated: AccumulatedPeers
}
public func makoshGroupPeerDirectory(transaction: Transaction, chats: [Api.Chat], users: [Api.User], requiredIds: Set<PeerId>) -> MakoshGroupPeerDirectory? {
    guard chats.count <= 2000, users.count <= 2000, requiredIds.count <= 2000,
          Set(users.map { $0.peerId }).count == users.count else { return nil }
    let rawChats = chats.compactMap(parseTelegramGroupOrChannel)
    guard rawChats.count == chats.count, Set(rawChats.map { $0.id }).count == rawChats.count else { return nil }
    let accumulated = AccumulatedPeers(transaction: transaction, chats: chats, users: users)
    let ids = Set(users.map { $0.peerId } + rawChats.map { $0.id })
    guard requiredIds.isSubset(of: ids) else { return nil }
    var peers: [PeerId: Peer] = [:]
    for id in ids {
        guard id.id._internalGetInt64Value() > 0, let peer = accumulated.get(id) else { return nil }
        peers[id] = peer
    }
    return MakoshGroupPeerDirectory(peers: peers, accumulated: accumulated)
}
public func makoshCommitGroupPeerDirectory(transaction: Transaction, accountPeerId: PeerId, directory: MakoshGroupPeerDirectory) {
    updatePeers(transaction: transaction, accountPeerId: accountPeerId, peers: directory.accumulated)
}
public struct MakoshGroupAdminMessageTexts {
    public let previous: String?
    public let current: String?
    public let copyProtected: Bool
    public let unavailable: Bool
}
/// Validate the complete packet before appending any observation. The journal
/// participates in this transaction and never inserts into live chat history.
public func makoshGroupAdminObservations(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId,
    events: [Api.ChannelAdminLogEvent], peerIsForum: Bool = false) -> [Int64: MakoshGroupAdminMessageTexts]? {
    guard accountPeerId.namespace == Namespaces.Peer.CloudUser, accountPeerId.id._internalGetInt64Value() > 0,
          peerId.namespace == Namespaces.Peer.CloudChannel, peerId.id._internalGetInt64Value() > 0, events.count <= 50 else { return nil }
    var observations: [(StoreMessage, Bool)] = []
    var result: [Int64: MakoshGroupAdminMessageTexts] = [:]
    func read(_ api: Api.Message, allowEmpty: Bool = false) -> (StoreMessage?, Bool)? {
        if case let .messageEmpty(_, id, peer) = api {
            guard (id > 0 || (allowEmpty && id == 0)), peer.map({ $0.peerId == peerId }) ?? true else { return nil }
            return (nil, id > 0)
        }
        guard let message = StoreMessage(apiMessage: api, accountPeerId: accountPeerId, peerIsForum: peerIsForum),
              case let .Id(id) = message.id, id.peerId == peerId, id.namespace == Namespaces.Message.Cloud, id.id > 0,
              message.text.utf16.count <= 65536, message.attributes.count <= 256, message.media.count <= 64 else { return nil }
        return (message, false)
    }
    for event in events {
        switch event {
        case let .channelAdminLogEvent(id, date, userId, action):
            guard id > 0, date > 0, userId > 0, result[id] == nil else { return nil }
            var previous: String?, current: String?, protected = false, unavailable = false
            switch action {
            case let .channelAdminLogEventActionEditMessage(before, after):
                guard let first = read(before), let second = read(after) else { return nil }
                if let a = first.0, let b = second.0 {
                    guard case let .Id(firstId) = a.id, case let .Id(secondId) = b.id, firstId == secondId else { return nil }
                }
                if let value = first.0 { previous = value.text; observations.append((value, false)); protected = value.flags.contains(.CopyProtected) }
                if let value = second.0 { current = value.text; observations.append((value, false)); protected = protected || value.flags.contains(.CopyProtected) }
                unavailable = first.1 || second.1
            case let .channelAdminLogEventActionDeleteMessage(api):
                guard let value = read(api) else { return nil }
                if let message = value.0 { current = message.text; observations.append((message, true)); protected = message.flags.contains(.CopyProtected) }
                unavailable = value.1
            case let .channelAdminLogEventActionSendMessage(api), let .channelAdminLogEventActionStopPoll(api):
                guard let value = read(api) else { return nil }
                if let message = value.0 { current = message.text; observations.append((message, false)); protected = message.flags.contains(.CopyProtected) }
                unavailable = value.1
            case let .channelAdminLogEventActionUpdatePinned(api):
                guard let value = read(api, allowEmpty: true) else { return nil }
                if let message = value.0 { current = message.text; observations.append((message, false)); protected = message.flags.contains(.CopyProtected) }
                unavailable = value.1
            default: break
            }
            result[id] = MakoshGroupAdminMessageTexts(previous: previous, current: current, copyProtected: protected, unavailable: unavailable)
        }
    }
    do { for (message, removed) in observations { try transaction.makoshArchiveObserve(message: message, removed: removed) } }
    catch { return nil }
    return result
}
'''
