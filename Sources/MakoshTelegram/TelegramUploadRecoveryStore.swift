import Foundation

/// Account-bound persistence; calls serialize on their original Postbox even
/// after UI cancellation or account replacement. It never submits to Telegram.
@MainActor protocol TelegramUploadRecoveryStore: AnyObject {
    var accountID: Int64 { get }
    func load(chatID: Int64) async throws -> TelegramPendingUploadDraft?
    func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                 captionInput: TelegramComposerInput, captionAboveMedia: Bool, originalDraft: TelegramComposerDraft?) async throws
    func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput, captionAboveMedia: Bool,
              disposition: TelegramPendingUploadDisposition) async throws
    func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile
}
