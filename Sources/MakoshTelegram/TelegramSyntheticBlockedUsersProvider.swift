#if DEBUG
import Foundation

@MainActor final class TelegramSyntheticBlockedUsersProvider: TelegramBlockedUsersProvider {
    let accountID: Int64 = -1
    private var users: [TelegramBlockedUser] = [.init(id: 8, title: "Synthetic Bob"), .init(id: 99, title: "Недоступное имя")]
    func load(receive: @escaping @MainActor (Result<TelegramBlockedUsersSnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        receive(.success(.init(accountID: accountID, users: users))); return SyntheticBlockedUsersRequest()
    }
    func apply(_ change: TelegramBlockedUserChange, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        guard change.accountID == accountID, users.contains(where: { $0.id == change.userID }) == change.wasBlocked else {
            receive(.failure(.changed)); return SyntheticBlockedUsersRequest()
        }
        if change.wasBlocked { users.removeAll { $0.id == change.userID } }
        else { users.insert(.init(id: change.userID, title: change.title), at: 0) }
        receive(.success(())); return SyntheticBlockedUsersRequest()
    }
}
@MainActor private final class SyntheticBlockedUsersRequest: TelegramPrivacyRequest { func cancel() {} }
#endif
