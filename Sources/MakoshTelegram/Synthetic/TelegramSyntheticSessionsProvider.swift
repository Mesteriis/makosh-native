#if DEBUG
import Foundation

@MainActor final class TelegramSyntheticSessionsProvider: TelegramSessionsProvider {
    let accountID: Int64 = -1
    private var snapshot: TelegramSessionsSnapshot
    init() {
        let now = Int32(Date().timeIntervalSince1970)
        func device(_ id: Int64, _ name: String, _ platform: String, pending: Bool = false) -> TelegramAccountSession {
            .init(id: id, device: name, platform: platform, systemVersion: "QA 1.0", app: "Telegram QA", appVersion: "1.0",
                ip: "192.0.2.1", country: "Тестовая страна", region: "Тестовый регион", apiID: 123, created: now - 86_400,
                active: now - Int32(id * 60), official: false, pending: pending, acceptsSecretChats: true, acceptsCalls: true)
        }
        snapshot = .init(accountID: -1, sessions: [device(0, "Mac · QA", "macOS"), device(9, "Телефон · QA", "iOS"),
            device(10, "Незавершённый вход · QA", "Windows", pending: true)], ttlDays: 31)
    }
    func load(receive: @escaping @MainActor (Result<TelegramSessionsSnapshot, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
        receive(.success(snapshot)); return SyntheticSessionsRequest()
    }
    func apply(_ change: TelegramSessionChange, expected: TelegramSessionsSnapshot,
        receive: @escaping @MainActor (Result<Void, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest {
        let request = SyntheticSessionsRequest()
        guard telegramAdmitSessionChange(expected: expected, current: snapshot, change: change) else { receive(.failure(.changed)); return request }
        var values = snapshot.sessions, ttl = snapshot.ttlDays
        switch change {
        case let .terminate(target): values.removeAll { $0.id == target.id }
        case .terminateOthers: values.removeAll { !$0.isCurrent }
        case let .ttl(days): ttl = days
        case let .secretChats(target, accepts), let .calls(target, accepts):
            values = values.map { session in
                guard session.id == target.id else { return session }
                let secret: Bool, calls: Bool
                if case .secretChats = change { secret = accepts; calls = session.acceptsCalls }
                else { secret = session.acceptsSecretChats; calls = accepts }
                return .init(id: session.id, device: session.device, platform: session.platform, systemVersion: session.systemVersion,
                    app: session.app, appVersion: session.appVersion, ip: session.ip, country: session.country, region: session.region,
                    apiID: session.apiID, created: session.created, active: session.active, official: session.official,
                    pending: session.pending, acceptsSecretChats: secret, acceptsCalls: calls)
            }
        }
        snapshot = .init(accountID: accountID, sessions: values, ttlDays: ttl)
        receive(.success(())); return request
    }
}
@MainActor private final class SyntheticSessionsRequest: TelegramSessionsRequest { func cancel() {} }
#endif
