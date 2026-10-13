#if DEBUG
import Foundation

@MainActor final class TelegramSyntheticPrivacyProvider: TelegramPrivacyProvider {
    let accountID: Int64 = -1
    private let capabilities: TelegramPrivacyCapabilities
    private var global = TelegramGlobalPrivacySetting(flags: (1 << 1) | (1 << 2) | (1 << 6), paidStars: nil, giftFlags: 0)
    init(premium: Bool = true) {
        capabilities = .init(isPremium: premium, nonPremiumMessageRestrictionAvailable: false, paidMessagesAvailable: true, maximumPaidStars: 10000)
    }
    private var settings = Dictionary(uniqueKeysWithValues: TelegramPrivacyKind.allCases.map { kind in
        let rules: [TelegramPrivacyRule] = switch kind {
        case .presence: [.allowUsers([7]), .denyChats([9]), .contacts, .premium]
        case .bio: [.allowUsers([8]), .denyChats([10]), .contacts, .everybody, .denyBots]
        default: [.contacts]
        }
        return (kind, TelegramPrivacySetting(kind: kind, rules: rules))
    })
    func load(receive: @escaping @MainActor (Result<TelegramPrivacySnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        receive(.success(.init(accountID: accountID, settings: settings, global: global, capabilities: capabilities))); return SyntheticPrivacyRequest()
    }
    func peers(query: String, include: [TelegramPrivacyPeerID], receive: @escaping @MainActor (Result<TelegramPrivacyPeerDirectory, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        let peers: [TelegramPrivacyPeer] = [.init(id: .user(7), title: "Synthetic Alice"), .init(id: .user(8), title: "Synthetic Bob"),
            .init(id: .chat(9), title: "Synthetic Group"), .init(id: .chat(10), title: "Synthetic Team")]
        let candidates = peers.filter { peer in
            if !query.isEmpty { return peer.title.localizedCaseInsensitiveContains(query) }
            if case .user = peer.id { return true }; return false
        }
        receive(.success(.init(accountID: accountID, candidates: candidates,
            existing: peers.filter { include.contains($0.id) }, hasMore: false)))
        return SyntheticPrivacyRequest()
    }
    func apply(_ change: TelegramPrivacyChange, expectedAccountID: Int64, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        guard let current = settings[change.expected.kind],
              change.expected.kind != .voiceMessages || capabilities.isPremium,
              telegramAdmitPrivacyChange(accountID: accountID, expectedAccountID: expectedAccountID, current: current, change: change),
              let value = change.replacement else { receive(.failure(.changed)); return SyntheticPrivacyRequest() }
        settings[value.kind] = value; receive(.success(())); return SyntheticPrivacyRequest()
    }
    func applyGlobal(_ change: TelegramGlobalPrivacyChange, expectedAccountID: Int64, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        guard expectedAccountID == accountID, global == change.expected, let replacement = change.replacement(capabilities: capabilities) else {
            receive(.failure(.changed)); return SyntheticPrivacyRequest()
        }
        global = replacement; receive(.success(())); return SyntheticPrivacyRequest()
    }
}
@MainActor private final class SyntheticPrivacyRequest: TelegramPrivacyRequest { func cancel() {} }
#endif
