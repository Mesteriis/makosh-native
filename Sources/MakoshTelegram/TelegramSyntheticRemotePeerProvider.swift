#if DEBUG
import Foundation

@MainActor final class TelegramSyntheticRemotePeerProvider: TelegramRemotePeerProvider {
    let accountID: Int64 = -1
    private let peers: [TelegramDiscoveredPeer] = [
        .init(chat: .init(id: 970001, title: "Synthetic Remote Alice", preview: "", unreadCount: 0), username: "alice_external"),
        .init(chat: .init(id: 970002, title: "Synthetic Remote Bob", preview: "", unreadCount: 0), username: "bob_external")
    ]
    func search(query: String, receive: @escaping @MainActor (Result<[TelegramDiscoveredPeer], TelegramRemotePeerError>) -> Void) -> any TelegramRemotePeerRequest {
        if query == "synthetic_failure" { receive(.failure(.failed)) }
        else { receive(.success(peers.filter { $0.chat.title.localizedCaseInsensitiveContains(query) || $0.username?.localizedCaseInsensitiveContains(query) == true })) }
        return SyntheticRemoteRequest()
    }
    func resolve(peerID: Int64, receive: @escaping @MainActor (Result<TelegramChat, TelegramRemotePeerError>) -> Void) -> any TelegramRemotePeerRequest {
        if let peer = peers.first(where: { $0.id == peerID }) { receive(.success(peer.chat)) }
        else { receive(.failure(.changed)) }
        return SyntheticRemoteRequest()
    }
}
@MainActor private final class SyntheticRemoteRequest: TelegramRemotePeerRequest { func cancel() {} }
#endif
