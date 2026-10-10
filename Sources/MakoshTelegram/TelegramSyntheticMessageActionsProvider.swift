#if DEBUG
import Foundation

/// Explicit offline UI simulation. Never owns an Account or invokes the engine.
@MainActor final class TelegramSyntheticMessageActionsProvider: TelegramMessageActionsProvider {
    let accountID: Int64 = -1
    func start(action: TelegramMessageAction, source: TelegramMessageActionSource,
               receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
        let lease = SyntheticMessageActionsLease()
        guard source.accountID == accountID, telegramMessageActionAllowed(action, source: source) else {
            receive(.rejected); return lease
        }
        lease.task = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                receive(.committing)
                try await Task.sleep(for: .milliseconds(350))
                switch action {
                case .edit, .editFormatted: receive(.applied)
                default: receive(.queued)
                }
            } catch { /* Cancels only this simulation. */ }
        }
        return lease
    }
}
@MainActor private final class SyntheticMessageActionsLease: TelegramMessageActionsLease {
    var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil }
    isolated deinit { cancel() }
}
#endif
