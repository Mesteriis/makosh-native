import Foundation

public enum TelegramPrivacyExceptionSide: String, Identifiable, Sendable { case allow, deny; public var id: String { rawValue } }
public enum TelegramPrivacyPeerID: Hashable, Sendable, Identifiable {
    case user(Int64), chat(Int64)
    public var id: String { switch self { case let .user(id): "user:\(id)"; case let .chat(id): "chat:\(id)" } }
    var rawID: Int64 { switch self { case let .user(id), let .chat(id): id } }
}
public struct TelegramPrivacyPeer: Equatable, Sendable, Identifiable {
    public let id: TelegramPrivacyPeerID
    public let title: String
    public init(id: TelegramPrivacyPeerID, title: String) { self.id = id; self.title = title }
}
extension TelegramPrivacySetting {
    public func exceptionPeers(_ side: TelegramPrivacyExceptionSide) -> [TelegramPrivacyPeerID] {
        rules.flatMap { rule -> [TelegramPrivacyPeerID] in
            switch (side, rule) {
            case let (.allow, .allowUsers(ids)), let (.deny, .denyUsers(ids)): ids.map { .user($0) }
            case let (.allow, .allowChats(ids)), let (.deny, .denyChats(ids)): ids.map { .chat($0) }
            default: []
            }
        }
    }
    public func replacingExceptions(_ side: TelegramPrivacyExceptionSide, peers: [TelegramPrivacyPeerID]) -> TelegramPrivacySetting? {
        guard audience != nil, kind != .phoneDiscovery, peers.allSatisfy({ $0.rawID > 0 }),
              peers.count <= 2048, Set(peers).count == peers.count,
              Set(exceptionPeers(side)).count == exceptionPeers(side).count,
              Set(peers) != Set(exceptionPeers(side)) else { return nil }
        let users = peers.compactMap { if case let .user(id) = $0 { id } else { nil } }
        let chats = peers.compactMap { if case let .chat(id) = $0 { id } else { nil } }
        guard users.count <= 1024, chats.count <= 1024 else { return nil }
        var inserted = false, updated: [TelegramPrivacyRule] = []
        func insert() {
            guard !inserted else { return }; inserted = true
            if !users.isEmpty { updated.append(side == .allow ? .allowUsers(users) : .denyUsers(users)) }
            if !chats.isEmpty { updated.append(side == .allow ? .allowChats(chats) : .denyChats(chats)) }
        }
        for rule in rules {
            switch (side, rule) {
            case (.allow, .allowUsers), (.allow, .allowChats), (.deny, .denyUsers), (.deny, .denyChats): insert()
            case let (.allow, .denyUsers(ids)), let (.deny, .allowUsers(ids)):
                let remaining = ids.filter { !users.contains($0) }
                if remaining == ids { updated.append(rule) }
                else if !remaining.isEmpty { updated.append(side == .allow ? .denyUsers(remaining) : .allowUsers(remaining)) }
            case let (.allow, .denyChats(ids)), let (.deny, .allowChats(ids)):
                let remaining = ids.filter { !chats.contains($0) }
                if remaining == ids { updated.append(rule) }
                else if !remaining.isEmpty { updated.append(side == .allow ? .denyChats(remaining) : .allowChats(remaining)) }
            default:
                if rule.isBase { insert() }; updated.append(rule)
            }
        }
        let result = TelegramPrivacySetting(kind: kind, rules: updated)
        return result.isValid ? result : nil
    }
}
