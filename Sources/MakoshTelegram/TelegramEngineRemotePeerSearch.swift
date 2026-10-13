import Foundation
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit

func telegramRemotePeerSearchRPC(_ raw: String) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.contacts.Found>)? {
    guard let query = TelegramRemotePeerQuery(raw) else { return nil }
    return Api.functions.contacts.search(q: query.value, limit: 20)
}
func telegramDiscoveredPeer(_ peer: Peer, accountID: Int64) -> TelegramDiscoveredPeer? {
    guard peer.id.id._internalGetInt64Value() > 0 else { return nil }
    let username: String?
    if let user = peer as? TelegramUser {
        guard user.firstName != nil || user.lastName != nil else { return nil }
        if user.id.toInt64() != accountID { guard case let .personal(hash) = user.accessHash, hash != 0 else { return nil } }
        username = user.addressName
    } else if let channel = peer as? TelegramChannel {
        guard channel.accessHash != nil else { return nil }; username = channel.addressName
    } else if let group = peer as? TelegramGroup {
        guard group.membership == .Member, group.migrationReference == nil, !group.flags.contains(.deactivated) else { return nil }; username = nil
    } else { return nil }
    let value = TelegramDiscoveredPeer(chat: .init(id: peer.id.toInt64(), title: telegramPeerTitle(peer), preview: "", unreadCount: 0), username: username)
    return value.isValid ? value : nil
}
private func telegramRemoteSearchSignal(account: Account, query: String) -> Signal<[TelegramDiscoveredPeer], TelegramRemotePeerError> {
    guard let rpc = telegramRemotePeerSearchRPC(query) else { return .fail(.unavailable) }
    return account.network.request(rpc, automaticFloodWait: false) |> mapError { _ in TelegramRemotePeerError.failed }
        |> mapToSignal { result in
            account.postbox.transaction { transaction -> [TelegramDiscoveredPeer]? in
                guard let (my, global) = makoshRemotePeerSearchResult(transaction: transaction, accountPeerId: account.peerId, result: result) else { return nil }
                let first = my.compactMap { telegramDiscoveredPeer($0.peer, accountID: account.peerId.toInt64()) }
                let second = global.compactMap { telegramDiscoveredPeer($0.peer, accountID: account.peerId.toInt64()) }
                guard first.count == my.count, second.count == global.count else { return nil }
                return telegramMergeDiscoveredPeers(my: first, global: second)
            } |> castError(TelegramRemotePeerError.self) |> mapToSignal { value -> Signal<[TelegramDiscoveredPeer], TelegramRemotePeerError> in
                guard let value else { return .fail(.unavailable) }; return .single(value)
            }
        }
}
private func telegramRemoteResolveSignal(account: Account, peerID: Int64) -> Signal<TelegramChat, TelegramRemotePeerError> {
    account.postbox.transaction { transaction in
        transaction.getPeer(PeerId(peerID)).flatMap { telegramDiscoveredPeer($0, accountID: account.peerId.toInt64()) }?.chat
    } |> castError(TelegramRemotePeerError.self) |> mapToSignal { value -> Signal<TelegramChat, TelegramRemotePeerError> in
        guard let value else { return .fail(.changed) }; return .single(value)
    }
}
@MainActor final class TelegramEngineRemotePeerProvider: TelegramRemotePeerProvider {
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func search(query: String, receive: @escaping @MainActor (Result<[TelegramDiscoveredPeer], TelegramRemotePeerError>) -> Void) -> any TelegramRemotePeerRequest {
        remoteRequest(telegramRemoteSearchSignal(account: account, query: query), receive: receive)
    }
    func resolve(peerID: Int64, receive: @escaping @MainActor (Result<TelegramChat, TelegramRemotePeerError>) -> Void) -> any TelegramRemotePeerRequest {
        remoteRequest(telegramRemoteResolveSignal(account: account, peerID: peerID), receive: receive)
    }
    private func remoteRequest<T>(_ signal: Signal<T, TelegramRemotePeerError>, receive: @escaping @MainActor (Result<T, TelegramRemotePeerError>) -> Void) -> any TelegramRemotePeerRequest {
        let request = RemoteRequest(); let delivered = Atomic(value: false)
        request.disposable.set((signal |> deliverOnMainQueue).start(next: { value in
            _ = delivered.swap(true); MainActor.assumeIsolated { receive(.success(value)) }
        }, error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }, completed: {
            if !delivered.with({ $0 }) { MainActor.assumeIsolated { receive(.failure(.failed)) } }
        }))
        return request
    }
}
@MainActor private final class RemoteRequest: TelegramRemotePeerRequest {
    let disposable = MetaDisposable()
    func cancel() { disposable.dispose() }
}
