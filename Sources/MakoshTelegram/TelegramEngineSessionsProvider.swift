import Foundation
import TelegramCore
import TelegramApi
import SwiftSignalKit

func telegramSessionRPC(_ change: TelegramSessionChange) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.Bool>)? {
    switch change {
    case let .terminate(session):
        guard !session.isCurrent else { return nil }
        return Api.functions.account.resetAuthorization(hash: session.id)
    case .terminateOthers: return Api.functions.auth.resetAuthorizations()
    case let .ttl(days):
        guard [7, 31, 93, 186].contains(days) else { return nil }
        return Api.functions.account.setAuthorizationTTL(authorizationTtlDays: days)
    case let .secretChats(session, accepts):
        return Api.functions.account.changeAuthorizationSettings(flags: 1, hash: session.id, encryptedRequestsDisabled: accepts ? .boolFalse : .boolTrue, callRequestsDisabled: nil)
    case let .calls(session, accepts):
        return Api.functions.account.changeAuthorizationSettings(flags: 2, hash: session.id, encryptedRequestsDisabled: nil, callRequestsDisabled: accepts ? .boolFalse : .boolTrue)
    }
}
func telegramSessionAcknowledged(_ value: Api.Bool) -> Bool { if case .boolTrue = value { true } else { false } }
func telegramPerformSessionChange(expected: TelegramSessionsSnapshot, change: TelegramSessionChange,
    load: () -> Signal<TelegramSessionsSnapshot, TelegramSessionsError>,
    perform: @escaping (TelegramSessionChange) -> Signal<Void, TelegramSessionsError>) -> Signal<Void, TelegramSessionsError> {
    guard expected.permits(change) else { return .fail(.changed) }
    let signal = load() |> take(1) |> mapToSignal { current -> Signal<Void, TelegramSessionsError> in
        guard telegramAdmitSessionChange(expected: expected, current: current, change: change) else { return .fail(.changed) }
        return perform(change)
    }
    return Signal { subscriber in
        let acknowledged = Atomic(value: false)
        return (signal |> take(1)).start(next: { _ in
            _ = acknowledged.swap(true); subscriber.putNext(())
        }, error: { subscriber.putError($0) }, completed: {
            if acknowledged.with({ $0 }) { subscriber.putCompletion() }
            else { subscriber.putError(.uncertain) }
        })
    }
}

private final class SessionsBackend {
    let account: Account
    init(account: Account) { self.account = account }
    func load() -> Signal<TelegramSessionsSnapshot, TelegramSessionsError> {
        let accountID = account.peerId.toInt64()
        return account.network.request(Api.functions.account.getAuthorizations(), automaticFloodWait: false)
            |> mapError { _ in TelegramSessionsError.failed } |> mapToSignal { response in
                guard let value = telegramSessionsSnapshot(response, accountID: accountID) else { return .fail(.failed) }
                return .single(value)
            }
    }
    func apply(_ change: TelegramSessionChange, expected: TelegramSessionsSnapshot) -> Signal<Void, TelegramSessionsError> {
        guard expected.accountID == account.peerId.toInt64() else { return .fail(.changed) }
        return telegramPerformSessionChange(expected: expected, change: change, load: load, perform: { [account] change in
            guard let rpc = telegramSessionRPC(change) else { return .fail(.changed) }
            // One bounded request. No retry/flood-wait wrapper for account mutations.
            return account.network.request(rpc, automaticFloodWait: false)
                |> mapError { telegramSessionWriteError(code: $0.errorCode, change: change) } |> mapToSignal { result in
                    telegramSessionAcknowledged(result) ? .single(()) : .fail(.failed)
                }
        })
    }
}
@MainActor final class TelegramEngineSessionsProvider: TelegramSessionsProvider {
    let accountID: Int64
    private let backend: SessionsBackend
    init(account: Account) { accountID = account.peerId.toInt64(); backend = .init(account: account) }
    func load(receive: @escaping @MainActor (Result<TelegramSessionsSnapshot, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
        let request = SessionsRequest()
        request.disposable.set((backend.load() |> deliverOnMainQueue).start(
            next: { value in MainActor.assumeIsolated { receive(.success(value)) } },
            error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
    func apply(_ change: TelegramSessionChange, expected: TelegramSessionsSnapshot,
        receive: @escaping @MainActor (Result<Void, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
        let request = SessionsRequest()
        request.disposable.set((backend.apply(change, expected: expected) |> deliverOnMainQueue).start(
            next: { MainActor.assumeIsolated { receive(.success(())) } },
            error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
}
@MainActor private final class SessionsRequest: TelegramSessionsRequest {
    let disposable = MetaDisposable()
    func cancel() { disposable.dispose() }
    isolated deinit { disposable.dispose() }
}
