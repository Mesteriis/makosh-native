import Foundation

/// Account-bound persistence; calls serialize on their original Postbox even
/// after UI cancellation or account replacement. It never submits to Telegram.
@MainActor protocol TelegramUploadRecoveryStore: AnyObject {
    var accountID: Int64 { get }
    func load(chatID: Int64) async throws -> TelegramPendingUploadDraft?
    func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                 captionInput: TelegramComposerInput, captionAboveMedia: Bool, mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?) async throws
    func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput, captionAboveMedia: Bool, mediaSpoiler: Bool,
              disposition: TelegramPendingUploadDisposition) async throws
    func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile
    func replaceVideoCover(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                           cover: TelegramUploadVideoCover?) async throws
    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, target: TelegramUploadTarget,
                 captionInput: TelegramComposerInput, captionAboveMedia: Bool, mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?) async throws
    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, presentation: TelegramUploadPresentation,
                 target: TelegramUploadTarget, captionInput: TelegramComposerInput, captionAboveMedia: Bool,
                 mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?) async throws
    func restoreItems(draft: TelegramPendingUploadDraft) async throws -> [TelegramUploadBatchItem]
    func updateItems(preparationID: UUID, previousIDs: [UUID], previousGrouping: Bool, orderedIDs: [UUID],
                     isGrouped: Bool, target: TelegramUploadTarget) async throws
    func updateItems(preparationID: UUID, previousIDs: [UUID], previousGrouping: Bool,
                     previousPresentation: TelegramUploadPresentation, orderedIDs: [UUID], isGrouped: Bool,
                     presentation: TelegramUploadPresentation, target: TelegramUploadTarget) async throws
    func updatePresentation(preparationID: UUID, orderedIDs: [UUID], previousPresentation: TelegramUploadPresentation,
                            previousGrouping: Bool, presentation: TelegramUploadPresentation, isGrouped: Bool,
                            target: TelegramUploadTarget) async throws
    func replaceVideoCover(preparationID: UUID, itemID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                           cover: TelegramUploadVideoCover?) async throws
}

extension TelegramUploadRecoveryStore {
    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, presentation: TelegramUploadPresentation,
                 target: TelegramUploadTarget, captionInput: TelegramComposerInput, captionAboveMedia: Bool,
                 mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?) async throws {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }
    func updatePresentation(preparationID: UUID, orderedIDs: [UUID], previousPresentation: TelegramUploadPresentation,
                            previousGrouping: Bool, presentation: TelegramUploadPresentation, isGrouped: Bool,
                            target: TelegramUploadTarget) async throws {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }
    // Legacy adapters fail closed until they explicitly implement whole-set writes.
    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, target: TelegramUploadTarget,
                 captionInput: TelegramComposerInput, captionAboveMedia: Bool, mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?) async throws {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }
    func restoreItems(draft: TelegramPendingUploadDraft) async throws -> [TelegramUploadBatchItem] {
        guard draft.schemaVersion < 6 else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        return [.init(id: draft.items[0].id, file: try await restoreFile(draft: draft))]
    }
    func updateItems(preparationID: UUID, previousIDs: [UUID], previousGrouping: Bool, orderedIDs: [UUID],
                     isGrouped: Bool, target: TelegramUploadTarget) async throws {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }
    func updateItems(preparationID: UUID, previousIDs: [UUID], previousGrouping: Bool,
                     previousPresentation: TelegramUploadPresentation, orderedIDs: [UUID], isGrouped: Bool,
                     presentation: TelegramUploadPresentation, target: TelegramUploadTarget) async throws {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }
    func replaceVideoCover(preparationID: UUID, itemID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                           cover: TelegramUploadVideoCover?) async throws {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }
}
