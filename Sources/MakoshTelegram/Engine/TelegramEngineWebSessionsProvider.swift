import Foundation
import TelegramCore
import TelegramApi
import SwiftSignalKit

func telegramWebSessionRPC(_ change: TelegramWebSessionChange) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.Bool>)? {
    switch change {
    case let .terminate(session):
        guard session.id != 0 else { return nil }
        return Api.functions.account.resetWebAuthorization(hash: session.id)
    case .terminateAll: return Api.functions.account.resetWebAuthorizations()
    }
}
func telegramPerformWebSessionChange(expected: TelegramWebSessionsSnapshot, change: TelegramWebSessionChange,
    load: () -> Signal<TelegramWebSessionsSnapshot, TelegramSessionsError>,
    perform: @escaping (TelegramWebSessionChange) -> Signal<Void, TelegramSessionsError>) -> Signal<Void, TelegramSessionsError> {
    guard expected.permits(change) else { return .fail(.changed) }
    let signal = load() |> take(1) |> mapToSignal { current -> Signal<Void, TelegramSessionsError> in
        guard telegramAdmitWebSessionChange(expected: expected, current: current, change: change) else { return .fail(.changed) }
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

private final class WebSessionsBackend {
    let account: Account
    init(account: Account) { self.account = account }
    func load() -> Signal<TelegramWebSessionsSnapshot, TelegramSessionsError> {
        let accountID = account.peerId.toInt64()
        return account.network.request(Api.functions.account.getWebAuthorizations(), automaticFloodWait: false)
            |> mapError { _ in TelegramSessionsError.failed } |> mapToSignal { response in
                guard let value = telegramWebSessionsSnapshot(response, accountID: accountID) else { return .fail(.failed) }
                return .single(value)
            }
    }
    func apply(_ change: TelegramWebSessionChange, expected: TelegramWebSessionsSnapshot) -> Signal<Void, TelegramSessionsError> {
        guard expected.accountID == account.peerId.toInt64() else { return .fail(.changed) }
        return telegramPerformWebSessionChange(expected: expected, change: change, load: load, perform: { [account] change in
            guard let rpc = telegramWebSessionRPC(change) else { return .fail(.changed) }
            // One bounded request. No retry/flood-wait wrapper for account mutations.
            return account.network.request(rpc, automaticFloodWait: false)
                |> mapError { (400..<500).contains($0.errorCode) ? TelegramSessionsError.failed : .uncertain } |> mapToSignal { result in
                    telegramSessionAcknowledged(result) ? .single(()) : .fail(.failed)
                }
        })
    }
}
@MainActor final class TelegramEngineWebSessionsProvider: TelegramWebSessionsProvider {
    let accountID: Int64
    private let backend: WebSessionsBackend
    init(account: Account) { accountID = account.peerId.toInt64(); backend = .init(account: account) }
    func load(receive: @escaping @MainActor (Result<TelegramWebSessionsSnapshot, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
        let request = WebSessionsRequest()
        request.disposable.set((backend.load() |> deliverOnMainQueue).start(
            next: { value in MainActor.assumeIsolated { receive(.success(value)) } },
            error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
    func apply(_ change: TelegramWebSessionChange, expected: TelegramWebSessionsSnapshot,
        receive: @escaping @MainActor (Result<Void, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
        let request = WebSessionsRequest()
        request.disposable.set((backend.apply(change, expected: expected) |> deliverOnMainQueue).start(
            next: { MainActor.assumeIsolated { receive(.success(())) } },
            error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
}
@MainActor private final class WebSessionsRequest: TelegramSessionsRequest {
    let disposable = MetaDisposable()
    func cancel() { disposable.dispose() }
    isolated deinit { disposable.dispose() }
}
