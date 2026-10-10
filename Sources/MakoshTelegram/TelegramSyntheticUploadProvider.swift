#if DEBUG
import Foundation

/// Explicit UI fixture only. No account, network, queue transaction or delivery.
@MainActor
final class TelegramSyntheticUploadProvider: TelegramUploadProvider {
    let accountID: Int64 = -1
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, caption: TelegramFormattedText,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        let lease = SyntheticUploadLease()
        guard target.accountID == accountID, target.hasValidReplySource, telegramFormattedCaptionCanSend(caption) else {
            receive(.rejected); return lease
        }
        lease.task = Task { [weak lease] in
            do {
                try await Task.sleep(for: .milliseconds(600))
                guard lease != nil else { return }
                receive(.committing)
                try await Task.sleep(for: .milliseconds(600))
                receive(.accepted("synthetic-local:" + UUID().uuidString))
                for progress in [0.1, 0.5, 1.0] {
                    receive(.progress(progress))
                    try await Task.sleep(for: .milliseconds(600))
                }
                receive(.progress(nil))
            } catch { /* Only stops fixture observation, never a real send. */ }
        }
        return lease
    }
}

@MainActor
private final class SyntheticUploadLease: TelegramUploadLease {
    var task: Task<Void, Never>?
    func stop() { task?.cancel(); task = nil }
    isolated deinit { stop() }
}
#endif
