#if DEBUG
import Foundation

@MainActor final class TelegramSyntheticQRLoginProvider: TelegramQRLoginProvider {
    private final class Request: TelegramQRLoginRequest { func cancel() {} }
    func request(receive: @escaping @MainActor (Result<TelegramQRLoginResult, TelegramQRLoginError>) -> Void) -> any TelegramQRLoginRequest {
        receive(.success(.token(Data("MAKOSH_SYNTHETIC_QA_NOT_A_LOGIN_TOKEN".utf8), expiresAt: Date().addingTimeInterval(60))))
        return Request()
    }
    func observeEvents(receive: @escaping @MainActor () -> Void) -> any TelegramQRLoginRequest { Request() }
}
#endif
