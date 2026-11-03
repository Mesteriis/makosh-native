#if DEBUG
import Foundation
@MainActor final class TelegramSyntheticWebSessionsProvider: TelegramWebSessionsProvider {
    let accountID: Int64 = -1
    private var sessions: [TelegramWebSession] = [
        .init(id: 9, botID: 42, domain: "synthetic.example", browser: "QA Browser", platform: "macOS QA", created: 1_700_000_000, active: 1_700_000_060, ip: "192.0.2.1", region: "Тестовый регион")
    ]
    func load(receive: @escaping @MainActor (Result<TelegramWebSessionsSnapshot, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
        receive(.success(.init(accountID: accountID, sessions: sessions))); return Request()
    }
    func apply(_ change: TelegramWebSessionChange, expected: TelegramWebSessionsSnapshot, receive: @escaping @MainActor (Result<Void, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
        guard telegramAdmitWebSessionChange(expected: expected, current: .init(accountID: accountID, sessions: sessions), change: change) else { receive(.failure(.changed)); return Request() }
        switch change { case let .terminate(target): sessions.removeAll { $0.id == target.id }; case .terminateAll: sessions.removeAll() }
        receive(.success(())); return Request()
    }
    private final class Request: TelegramSessionsRequest { func cancel() {} }
}
#endif
