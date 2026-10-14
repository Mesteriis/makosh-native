import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

@MainActor final class TelegramEngineQRLoginProvider: TelegramQRLoginProvider {
    private let account: UnauthorizedAccount
    private let manager: AccountManager<TelegramAccountManagerTypes>
    private let replace: @MainActor (UnauthorizedAccount, Bool) -> Void
    init(account: UnauthorizedAccount, manager: AccountManager<TelegramAccountManagerTypes>, replace: @escaping @MainActor (UnauthorizedAccount, Bool) -> Void) {
        self.account = account; self.manager = manager; self.replace = replace
    }
    func request(receive: @escaping @MainActor (Result<TelegramQRLoginResult, TelegramQRLoginError>) -> Void) -> any TelegramQRLoginRequest {
        let request = Request(), account = self.account, replace = self.replace
        let seen = Atomic(value: false)
        request.disposable.set((TelegramEngineUnauthorized(account: account).auth.exportAuthTransferToken(accountManager: manager, otherAccountUserIds: [], syncContacts: false)
            |> take(1) |> deliverOnMainQueue).start(next: { result in
                _ = seen.swap(true)
                MainActor.assumeIsolated {
                    switch result {
                    case let .displayToken(token):
                        let remaining = Double(token.validUntil) - account.network.globalTime
                        receive(.success(.token(token.value, expiresAt: Date().addingTimeInterval(remaining))))
                    case let .changeAccountAndRetry(next): replace(next, true)
                    case let .passwordRequested(next): replace(next, false); receive(.success(.password))
                    case .loggedIn: receive(.success(.authorized))
                    }
                }
            }, error: { _ in MainActor.assumeIsolated { receive(.failure(.failed)) } }, completed: {
                if !seen.with({ $0 }) { MainActor.assumeIsolated { receive(.failure(.failed)) } }
            }))
        return request
    }
    func observeEvents(receive: @escaping @MainActor () -> Void) -> any TelegramQRLoginRequest {
        let request = Request()
        request.disposable.set((account.updateLoginTokenEvents |> deliverOnMainQueue).start(next: { _ in MainActor.assumeIsolated { receive() } }))
        return request
    }
    private final class Request: TelegramQRLoginRequest {
        let disposable = MetaDisposable()
        func cancel() { disposable.dispose() }
        isolated deinit { disposable.dispose() }
    }
}
