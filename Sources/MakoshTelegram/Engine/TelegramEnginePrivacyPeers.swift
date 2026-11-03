import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

nonisolated func telegramPrivacyCandidate(_ peer: Peer, selfID: Int64) -> TelegramPrivacyPeer? {
    let id = peer.id.id._internalGetInt64Value()
    guard id > 0 else { return nil }
    let key: TelegramPrivacyPeerID
    if let user = peer as? TelegramUser {
        guard id != selfID, case let .personal(hash) = user.accessHash, hash != 0 else { return nil }
        key = .user(id)
    } else if let group = peer as? TelegramGroup {
        guard group.membership == .Member, group.migrationReference == nil, !group.flags.contains(.deactivated) else { return nil }
        key = .chat(id)
    } else if let channel = peer as? TelegramChannel {
        guard case .group = channel.info, channel.participationStatus == .member else { return nil }
        key = .chat(id)
    } else { return nil }
    return .init(id: key, title: privacyPeerTitle(peer))
}
private nonisolated func privacyPeerTitle(_ peer: Peer) -> String {
    let title = telegramPeerTitle(peer).trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Недоступное имя" : String(title.prefix(512))
}
private nonisolated func privacyNativePeers(_ key: TelegramPrivacyPeerID, transaction: Transaction) -> [Peer] {
    let namespaces: [PeerId.Namespace] = switch key {
    case .user: [Namespaces.Peer.CloudUser]
    case .chat: [Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel]
    }
    return namespaces.compactMap { transaction.getPeer(PeerId(namespace: $0, id: ._internalFromInt64Value(key.rawID))) }
}
nonisolated func telegramPrivacyAdditionIDs(current: TelegramPrivacySetting, sent: TelegramPrivacySetting) -> Set<TelegramPrivacyPeerID> {
    Set(sent.exceptionPeers(.allow) + sent.exceptionPeers(.deny)).subtracting(current.exceptionPeers(.allow) + current.exceptionPeers(.deny))
}
nonisolated func telegramPrivacyAdditionHashes(current: TelegramPrivacySetting, sent: TelegramPrivacySetting,
    freshHashes: [Int64: Int64], peers: [Peer], selfID: Int64) -> [Int64: Int64]? {
    var hashes = freshHashes
    for key in telegramPrivacyAdditionIDs(current: current, sent: sent) {
        let matching = peers.filter { peer in
            peer.id.id._internalGetInt64Value() == key.rawID && (key == .user(key.rawID) ? peer is TelegramUser : peer is TelegramGroup || peer is TelegramChannel)
        }
        guard matching.count == 1, let peer = matching.first, telegramPrivacyCandidate(peer, selfID: selfID)?.id == key else { return nil }
        if let user = peer as? TelegramUser, case let .personal(hash) = user.accessHash { hashes[key.rawID] = hash }
    }
    return hashes
}
nonisolated func telegramPrivacyResolveAdditions(transaction: Transaction, current: TelegramPrivacySetting, sent: TelegramPrivacySetting,
    freshHashes: [Int64: Int64], selfID: Int64) -> [Int64: Int64]? {
    if sent.kind == .voiceMessages {
        let id = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(selfID))
        guard telegramPrivacyCapabilities(transaction: transaction, peerID: id)?.isPremium == true else { return nil }
    }
    let peers = telegramPrivacyAdditionIDs(current: current, sent: sent).flatMap { privacyNativePeers($0, transaction: transaction) }
    return telegramPrivacyAdditionHashes(current: current, sent: sent, freshHashes: freshHashes, peers: peers, selfID: selfID)
}
nonisolated func telegramPrivacyPeerDirectory(transaction: Transaction, accountID: Int64, selfID: Int64,
    query: String, include: [TelegramPrivacyPeerID]) -> TelegramPrivacyPeerDirectory {
    let native: [Peer]
    if query.isEmpty { native = transaction.getContactPeerIds().sorted().compactMap { transaction.getPeer($0) } }
    else { native = transaction.searchPeers(query: query).compactMap(\.peer) }
    let peers = native.compactMap { telegramPrivacyCandidate($0, selfID: selfID) }
    // Basic groups and channels share the privacy wire-ID space. Never pick an ambiguous identity.
    let grouped = Dictionary(grouping: peers, by: \.id)
    let unique = peers.filter { grouped[$0.id]?.count == 1 }
    let existing = include.compactMap { key -> TelegramPrivacyPeer? in
        let matches = privacyNativePeers(key, transaction: transaction)
        guard matches.count == 1, let peer = matches.first else { return nil }
        return .init(id: key, title: privacyPeerTitle(peer))
    }
    return .init(accountID: accountID, candidates: Array(unique.prefix(200)), existing: existing, hasMore: unique.count > 200)
}

nonisolated func telegramPrivacySearch(postbox: Postbox, accountID: Int64, selfID: Int64, query: String,
    include: [TelegramPrivacyPeerID]) -> Signal<TelegramPrivacyPeerDirectory, NoError> {
    postbox.transaction { transaction in
        telegramPrivacyPeerDirectory(transaction: transaction, accountID: accountID, selfID: selfID, query: query, include: include)
    }
}
