# SPDX-License-Identifier: MIT
"""Own narrow cache bridge, compiled inside independently pinned TelegramCore."""

def remote_peer_helper_source():
    return '''// Own Makosh MIT adapter; linked TelegramCore remains GPL-3.0-or-later.
import Postbox
import TelegramApi

public func makoshRemotePeerSearchResult(transaction: Transaction, accountPeerId: PeerId, result: Api.contacts.Found) -> ([FoundPeer], [FoundPeer])? {
    switch result {
    case let .found(my, global, chats, users):
        guard my.count + global.count <= 200, chats.count <= 1000, users.count <= 1000,
              Set(users.map { $0.peerId }).count == users.count else { return nil }
        let accumulated = AccumulatedPeers(transaction: transaction, chats: chats, users: users)
        var first: [FoundPeer] = [], second: [FoundPeer] = []
        for (index, values) in [my, global].enumerated() {
            for value in values {
                let id = value.peerId
                guard id.id._internalGetInt64Value() > 0, let peer = accumulated.get(id) else { return nil }
                if let user = peer as? TelegramUser {
                    guard !user.isDeleted else { return nil }
                    if id != accountPeerId {
                        guard case let .personal(hash) = user.accessHash, hash != 0 else { return nil }
                    }
                } else if let channel = peer as? TelegramChannel {
                    guard channel.accessHash != nil else { return nil }
                } else if let group = peer as? TelegramGroup {
                    guard group.membership == .Member, group.migrationReference == nil, !group.flags.contains(.deactivated) else { return nil }
                } else { return nil }
                let found = FoundPeer(peer: peer, subscribers: nil)
                if index == 0 { first.append(found) } else { second.append(found) }
            }
        }
        updatePeers(transaction: transaction, accountPeerId: accountPeerId, peers: accumulated)
        return (first, second)
    }
}
'''
