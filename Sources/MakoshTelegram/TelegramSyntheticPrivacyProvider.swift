#if DEBUG
import Foundation

@MainActor final class TelegramSyntheticPrivacyProvider: TelegramPrivacyProvider {
    let accountID: Int64 = -1
    private var settings = Dictionary(uniqueKeysWithValues: TelegramPrivacyKind.allCases.map { kind in
        (kind, TelegramPrivacySetting(kind: kind, rules: kind == .presence ? [.allowUsers([7]), .denyChats([9]), .contacts, .premium] : [.contacts]))
    })
    func load(receive: @escaping @MainActor (Result<TelegramPrivacySnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        receive(.success(.init(accountID: accountID, settings: settings))); return SyntheticPrivacyRequest()
    }
    func apply(_ change: TelegramPrivacyChange, expectedAccountID: Int64, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        guard let current = settings[change.expected.kind],
              telegramAdmitPrivacyChange(accountID: accountID, expectedAccountID: expectedAccountID, current: current, change: change),
              let value = current.replacingAudience(change.audience) else { receive(.failure(.changed)); return SyntheticPrivacyRequest() }
        settings[value.kind] = value; receive(.success(())); return SyntheticPrivacyRequest()
    }
}
@MainActor private final class SyntheticPrivacyRequest: TelegramPrivacyRequest { func cancel() {} }
#endif
