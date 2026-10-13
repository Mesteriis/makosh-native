import Foundation
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit

struct TelegramBlockedPage {
    let users: [TelegramBlockedUser]
    let serverInputs: [Int64: Api.InputPeer]
    let totalCount: Int
    let nextOffset: Int?
}
func telegramBlockedServerInput(_ user: Api.User, selfID: Int64) -> Api.InputPeer? {
    guard case let .user(flags, _, id, hash, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = user,
          telegramBlockedNativeID(id) != nil, id != selfID, flags & (1 << 20) == 0, let hash, hash != 0 else { return nil }
    return .inputPeerUser(userId: id, accessHash: hash)
}
func telegramBlockedPage(_ response: Api.contacts.Blocked, offset: Int) -> TelegramBlockedPage? {
    let blocked: [Api.PeerBlocked], users: [Api.User], total: Int
    switch response {
    case let .blocked(values, _, names): blocked = values; users = names; total = offset + values.count
    case let .blockedSlice(count, values, _, names): blocked = values; users = names; total = Int(count)
    }
    guard offset >= 0, offset <= 10_000, blocked.count <= 200, users.count <= 200,
          total >= offset + blocked.count, total <= 10_000,
          !blocked.isEmpty || offset == total else { return nil }
    var names: [Int64: String] = [:], inputs: [Int64: Api.InputPeer] = [:]
    for user in users {
        let id: Int64, title: String
        switch user {
        case let .user(_, _, value, _, first, last, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _):
            id = value; title = [first,last].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        case let .userEmpty(value): id = value; title = ""
        }
        guard telegramBlockedNativeID(id) != nil, names[id] == nil else { return nil }
        if let input = telegramBlockedServerInput(user, selfID: 0) { inputs[id] = input }
        names[id] = title.isEmpty ? "Недоступное имя" : String(title.prefix(512))
    }
    var result: [TelegramBlockedUser] = [], seen: Set<Int64> = []
    for case let .peerBlocked(peer, _) in blocked {
        // This screen handles cloud users. An unsupported peer must never disappear silently.
        guard case let .peerUser(id) = peer, telegramBlockedNativeID(id) != nil, seen.insert(id).inserted else { return nil }
        result.append(.init(id: id, title: names[id] ?? "Недоступное имя"))
    }
    let next = offset + blocked.count
    return .init(users: result, serverInputs: inputs, totalCount: total, nextOffset: next < total ? next : nil)
}
private struct BlockedUsersRead {
    let snapshot: TelegramBlockedUsersSnapshot
    let inputs: [Int64: Api.InputPeer]
}
func telegramLoadBlockedUsers(accountID: Int64, fetch: @escaping (Int32) -> Signal<Api.contacts.Blocked, TelegramPrivacyError>) -> Signal<TelegramBlockedUsersSnapshot, TelegramPrivacyError> {
    telegramReadBlockedUsers(accountID: accountID, fetch: fetch) |> map(\.snapshot)
}
private func telegramReadBlockedUsers(accountID: Int64, fetch: @escaping (Int32) -> Signal<Api.contacts.Blocked, TelegramPrivacyError>) -> Signal<BlockedUsersRead, TelegramPrivacyError> {
    func page(offset: Int, total: Int?, previous: [TelegramBlockedUser], inputs: [Int64: Api.InputPeer]) -> Signal<BlockedUsersRead, TelegramPrivacyError> {
        fetch(Int32(offset)) |> take(1) |> mapToSignal { response in
            guard let value = telegramBlockedPage(response, offset: offset), total == nil || total == value.totalCount,
                  Set(previous.map(\.id)).isDisjoint(with: value.users.map(\.id)) else { return .fail(.failed) }
            let all = previous + value.users
            let hashes = inputs.merging(value.serverInputs.filter { key, _ in value.users.contains { $0.id == key } }) { _, new in new }
            if let next = value.nextOffset { return page(offset: next, total: value.totalCount, previous: all, inputs: hashes) }
            let result = TelegramBlockedUsersSnapshot(accountID: accountID, users: all)
            guard result.isValid else { return .fail(.failed) }
            return .single(.init(snapshot: result, inputs: hashes))
        }
    }
    return telegramBlockedValue(page(offset: 0, total: nil, previous: [], inputs: [:]), emptyError: .failed)
}
func telegramBlockedInput(user: TelegramUser, selfID: Int64) -> Api.InputPeer? {
    let id = user.id.id._internalGetInt64Value()
    guard user.id.namespace == Namespaces.Peer.CloudUser, id > 0, id != selfID,
          case let .personal(hash) = user.accessHash, hash != 0 else { return nil }
    return .inputPeerUser(userId: id, accessHash: hash)
}
func telegramBlockedRPC(block: Bool, input: Api.InputPeer) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.Bool>) {
    block ? Api.functions.contacts.block(flags: 0, id: input) : Api.functions.contacts.unblock(flags: 0, id: input)
}
func telegramPerformBlockedChange(accountID: Int64, change: TelegramBlockedUserChange,
    load: () -> Signal<TelegramBlockedUsersSnapshot, TelegramPrivacyError>,
    perform: @escaping () -> Signal<Api.Bool, TelegramPrivacyError>) -> Signal<Void, TelegramPrivacyError> {
    guard accountID == change.accountID, let nativeID = telegramBlockedNativeID(change.userID), nativeID != accountID else { return .fail(.changed) }
    let result = load() |> take(1) |> mapToSignal { current -> Signal<Void, TelegramPrivacyError> in
        guard current.isValid, current.accountID == accountID,
              current.users.contains(where: { $0.id == change.userID }) == change.wasBlocked else { return .fail(.changed) }
        return perform() |> take(1) |> mapToSignal { ack in
            guard case .boolTrue = ack else { return .fail(.uncertain) }
            return .single(())
        }
    }
    return telegramBlockedValue(result, emptyError: .uncertain)
}
private func telegramBlockedValue<T>(_ signal: Signal<T, TelegramPrivacyError>, emptyError: TelegramPrivacyError) -> Signal<T, TelegramPrivacyError> {
    Signal { subscriber in
        let received = Atomic(value: false)
        return (signal |> take(1)).start(next: { value in
            _ = received.swap(true); subscriber.putNext(value)
        }, error: { subscriber.putError($0) }, completed: {
            if received.with({ $0 }) { subscriber.putCompletion() } else { subscriber.putError(emptyError) }
        })
    }
}

// Construct legacy Postbox closures outside MainActor; they execute on its queue.
nonisolated func telegramBlockedUserInput(postbox: Postbox, userID: Int64, selfID: Int64) -> Signal<Api.InputPeer?, NoError> {
    guard telegramBlockedNativeID(userID) != nil else { return .single(nil) }
    return postbox.transaction { transaction in
        guard let user = transaction.getPeer(PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(userID))) as? TelegramUser else { return nil }
        return telegramBlockedInput(user: user, selfID: selfID)
    }
}
nonisolated func telegramCacheBlockedUser(postbox: Postbox, userID: Int64, blocked: Bool) -> Signal<Void, NoError> {
    postbox.transaction { transaction in
        let id = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(userID))
        transaction.updatePeerCachedData(peerIds: [id]) { _, current in
            ((current as? CachedUserData) ?? CachedUserData()).withUpdatedIsBlocked(blocked)
        }
    }
}
private final class BlockedUsersBackend {
    let account: Account
    init(account: Account) { self.account = account }
    private func read() -> Signal<BlockedUsersRead, TelegramPrivacyError> {
        telegramReadBlockedUsers(accountID: account.peerId.toInt64()) { [account] offset in
            account.network.request(Api.functions.contacts.getBlocked(flags: 0, offset: offset, limit: 200), automaticFloodWait: false)
                |> mapError { _ in TelegramPrivacyError.failed }
        }
    }
    func load() -> Signal<TelegramBlockedUsersSnapshot, TelegramPrivacyError> { read() |> map(\.snapshot) }
    func apply(_ change: TelegramBlockedUserChange) -> Signal<Void, TelegramPrivacyError> {
        guard change.accountID == account.peerId.toInt64() else { return .fail(.changed) }
        return read() |> mapToSignal { [account] fresh in
            telegramPerformBlockedChange(accountID: account.peerId.toInt64(), change: change, load: { .single(fresh.snapshot) }, perform: {
                let input: Signal<Api.InputPeer?, NoError>
                if change.wasBlocked { input = .single(fresh.inputs[change.userID]) }
                else { input = telegramBlockedUserInput(postbox: account.postbox, userID: change.userID, selfID: account.peerId.id._internalGetInt64Value()) }
                return input |> castError(TelegramPrivacyError.self) |> mapToSignal { input -> Signal<Api.Bool, TelegramPrivacyError> in
                    guard let input else { return .fail(.unavailable) }
                    return account.network.request(telegramBlockedRPC(block: !change.wasBlocked, input: input), automaticFloodWait: false)
                        |> mapError { (400..<500).contains($0.errorCode) ? TelegramPrivacyError.failed : .uncertain }
                }
            })
        } |> mapToSignal { [account] in
            telegramCacheBlockedUser(postbox: account.postbox, userID: change.userID, blocked: !change.wasBlocked)
                |> castError(TelegramPrivacyError.self)
        }
    }
}
@MainActor final class TelegramEngineBlockedUsersProvider: TelegramBlockedUsersProvider {
    let accountID: Int64
    private let backend: BlockedUsersBackend
    init(account: Account) { accountID = account.peerId.toInt64(); backend = .init(account: account) }
    func load(receive: @escaping @MainActor (Result<TelegramBlockedUsersSnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        let r = BlockedUsersRequest()
        r.disposable.set((backend.load() |> deliverOnMainQueue).start(next: { value in MainActor.assumeIsolated { receive(.success(value)) } }, error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return r
    }
    func apply(_ change: TelegramBlockedUserChange, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        let r = BlockedUsersRequest()
        r.disposable.set((backend.apply(change) |> deliverOnMainQueue).start(next: { _ in MainActor.assumeIsolated { receive(.success(())) } }, error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return r
    }
}
@MainActor private final class BlockedUsersRequest: TelegramPrivacyRequest {
    let disposable = MetaDisposable()
    func cancel() { disposable.dispose() }
    isolated deinit { disposable.dispose() }
}
