import Foundation
import TelegramCore
import TelegramApi
import SwiftSignalKit

func telegramPerformPrivacyChange(accountID: Int64, expectedAccountID: Int64, change: TelegramPrivacyChange,
    load: () -> Signal<TelegramPrivacySetting, TelegramPrivacyError>,
    perform: @escaping (TelegramPrivacySetting) -> Signal<TelegramPrivacySetting, TelegramPrivacyError>) -> Signal<TelegramPrivacySetting, TelegramPrivacyError> {
    guard accountID == expectedAccountID, change.expected.replacingAudience(change.audience) != nil else { return .fail(.changed) }
    let signal = load() |> take(1) |> mapToSignal { current -> Signal<TelegramPrivacySetting, TelegramPrivacyError> in
        guard telegramAdmitPrivacyChange(accountID: accountID, expectedAccountID: expectedAccountID, current: current, change: change),
              let sent = current.replacingAudience(change.audience) else { return .fail(.changed) }
        return perform(sent) |> take(1) |> mapToSignal { ack -> Signal<TelegramPrivacySetting, TelegramPrivacyError> in
            guard ack.kind == sent.kind, ack.isValid, ack.audience == sent.audience,
                  ack.rules.filter({ !$0.isBase }) == sent.rules.filter({ !$0.isBase }) else { return .fail(.uncertain) }
            return .single(ack)
        }
    }
    return telegramPrivacyAcknowledgement(signal)
}
private func telegramPrivacyAcknowledgement(_ signal: Signal<TelegramPrivacySetting, TelegramPrivacyError>) -> Signal<TelegramPrivacySetting, TelegramPrivacyError> {
    Signal { subscriber in
        let acknowledged = Atomic(value: false)
        return (signal |> take(1)).start(next: { value in
            _ = acknowledged.swap(true); subscriber.putNext(value)
        }, error: { subscriber.putError($0) }, completed: {
            if acknowledged.with({ $0 }) { subscriber.putCompletion() } else { subscriber.putError(.uncertain) }
        })
    }
}

func telegramPrivacyRPC(_ setting: TelegramPrivacySetting, userHashes: [Int64: Int64], selfID: Int64) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.account.PrivacyRules>)? {
    guard let rules = telegramPrivacyInputRules(setting, userHashes: userHashes, selfID: selfID) else { return nil }
    return Api.functions.account.setPrivacy(key: telegramPrivacyKey(setting.kind), rules: rules)
}

func telegramPrivacyUserHashes(_ users: [Api.User]) -> [Int64: Int64]? {
    guard users.count <= 4096 else { return nil }
    var seen: Set<Int64> = [], result: [Int64: Int64] = [:]
    for user in users {
        let id: Int64
        switch user {
        case let .user(flags, _, value, hash, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _):
            id = value
            if flags & (1 << 20) == 0, let hash, hash != 0 { result[id] = hash }
        case let .userEmpty(value): id = value
        }
        guard id > 0, seen.insert(id).inserted else { return nil }
    }
    return result
}

private final class PrivacyBackend {
    let account: Account
    init(account: Account) { self.account = account }
    func response(_ kind: TelegramPrivacyKind) -> Signal<Api.account.PrivacyRules, TelegramPrivacyError> {
        account.network.request(Api.functions.account.getPrivacy(key: telegramPrivacyKey(kind)), automaticFloodWait: false)
            |> mapError { _ in TelegramPrivacyError.failed }
    }
    func load() -> Signal<TelegramPrivacySnapshot, TelegramPrivacyError> {
        let requests = TelegramPrivacyKind.allCases.map { kind in
            response(kind) |> mapToSignal { response -> Signal<TelegramPrivacySetting, TelegramPrivacyError> in
                guard let value = telegramPrivacySetting(response, kind: kind) else { return .fail(.failed) }
                return .single(value)
            }
        }
        return combineLatest(requests) |> map { [account] values in
            TelegramPrivacySnapshot(accountID: account.peerId.toInt64(), settings: Dictionary(uniqueKeysWithValues: values.map { ($0.kind, $0) }))
        }
    }
    func apply(_ change: TelegramPrivacyChange, expectedAccountID: Int64) -> Signal<TelegramPrivacySetting, TelegramPrivacyError> {
        guard expectedAccountID == account.peerId.toInt64() else { return .fail(.changed) }
        let signal = response(change.expected.kind) |> take(1) |> mapToSignal { [account] response -> Signal<TelegramPrivacySetting, TelegramPrivacyError> in
            guard let fresh = telegramPrivacySetting(response, kind: change.expected.kind),
                  case let .privacyRules(_, _, users) = response, let hashes = telegramPrivacyUserHashes(users) else { return .fail(.unavailable) }
            return telegramPerformPrivacyChange(accountID: account.peerId.toInt64(), expectedAccountID: expectedAccountID, change: change,
                load: { .single(fresh) }, perform: { sent in
                    guard let rpc = telegramPrivacyRPC(sent, userHashes: hashes, selfID: account.peerId.id._internalGetInt64Value()) else { return .fail(.unavailable) }
                    // No application retry or flood-wait wrapper; the controller owns the deadline.
                    return account.network.request(rpc, automaticFloodWait: false)
                        |> mapError { (400..<500).contains($0.errorCode) ? TelegramPrivacyError.failed : .uncertain }
                        |> mapToSignal { response -> Signal<TelegramPrivacySetting, TelegramPrivacyError> in
                            guard let ack = telegramPrivacySetting(response, kind: sent.kind) else { return .fail(.uncertain) }
                            return .single(ack)
                        }
                })
        }
        return telegramPrivacyAcknowledgement(signal)
    }
}
@MainActor final class TelegramEnginePrivacyProvider: TelegramPrivacyProvider {
    let accountID: Int64
    private let backend: PrivacyBackend
    init(account: Account) { accountID = account.peerId.toInt64(); backend = .init(account: account) }
    func load(receive: @escaping @MainActor (Result<TelegramPrivacySnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        let request = PrivacyRequest()
        request.disposable.set((backend.load() |> deliverOnMainQueue).start(
            next: { value in MainActor.assumeIsolated { receive(.success(value)) } },
            error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
    func apply(_ change: TelegramPrivacyChange, expectedAccountID: Int64, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        let request = PrivacyRequest()
        request.disposable.set((backend.apply(change, expectedAccountID: expectedAccountID) |> deliverOnMainQueue).start(
            next: { _ in MainActor.assumeIsolated { receive(.success(())) } },
            error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
}
@MainActor private final class PrivacyRequest: TelegramPrivacyRequest {
    let disposable = MetaDisposable()
    func cancel() { disposable.dispose() }
    isolated deinit { disposable.dispose() }
}
