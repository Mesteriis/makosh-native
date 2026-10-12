import Foundation

/// Per-attempt cancellation and scope binding for a dedicated Archive install.
internal final class TelegramPendingUploadArchiveAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let accountID: Int64, chatID: Int64
    private let preparationID: UUID, expectedRevision: UUID, generation: UUID
    private var cancelled = false
    init(accountID: Int64, chatID: Int64, preparationID: UUID, expectedRevision: UUID, generation: UUID) {
        self.accountID = accountID; self.chatID = chatID; self.preparationID = preparationID
        self.expectedRevision = expectedRevision; self.generation = generation
    }
    func cancel() { lock.withLock { cancelled = true } }
    func check(accountID: Int64, chatID: Int64, preparationID: UUID, expectedRevision: UUID) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            guard matches(accountID: accountID, chatID: chatID, preparationID: preparationID, expectedRevision: expectedRevision) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
        }
    }
    // Only the bounded, synchronous native read/compare/set may run under this lock.
    // Invalidation before admission refuses the write; invalidation after admission
    // waits for that write and cannot roll it back. No async or caller callback here.
    func withAdmission(accountID: Int64, chatID: Int64, preparationID: UUID, expectedRevision: UUID,
                       _ write: () -> Result<Void, TelegramPendingUploadPersistenceError>)
        -> Result<Void, TelegramPendingUploadPersistenceError> {
        lock.withLock {
            guard !cancelled, matches(accountID: accountID, chatID: chatID,
                preparationID: preparationID, expectedRevision: expectedRevision) else { return .failure(.conflict) }
            return write()
        }
    }
    private func matches(accountID: Int64, chatID: Int64, preparationID: UUID, expectedRevision: UUID) -> Bool {
        self.accountID != 0 && self.chatID != 0 && self.preparationID != TelegramPendingUploadDraft.zeroUUID &&
        self.expectedRevision != TelegramPendingUploadDraft.zeroUUID && generation != TelegramPendingUploadDraft.zeroUUID &&
        self.accountID == accountID && self.chatID == chatID && self.preparationID == preparationID && self.expectedRevision == expectedRevision
    }
}
