import Foundation

/// Account-bound persistence; calls serialize on their original Postbox even
/// after UI cancellation or account replacement. It never submits to Telegram.
@MainActor protocol TelegramUploadRecoveryStore: AnyObject {
    var accountID: Int64 { get }
    func captureAppend(snapshot: TelegramPendingUploadDraft, additions: [TelegramUploadBatchItem],
                       target: TelegramUploadTarget) async throws -> TelegramUploadAppendCapture
    func installAppend(_ capture: TelegramUploadAppendCapture, target: TelegramUploadTarget) async throws -> TelegramPendingUploadDraft
    func loadArchiveCapture(chatID: Int64) async throws -> TelegramPendingUploadArchiveCapture?
    func installArchive(preparationID: UUID, expectedRevision: UUID, archive: TelegramPendingUploadArchive,
                        target: TelegramUploadTarget, admission: TelegramPendingUploadArchiveAdmission) async throws -> TelegramPendingUploadDraft
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
    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, presentation: TelegramUploadPresentation,
                 target: TelegramUploadTarget, captionInput: TelegramComposerInput, captionAboveMedia: Bool,
                 mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?, captionPolicy: TelegramUploadCaptionPolicy?) async throws
    func restoreItems(draft: TelegramPendingUploadDraft) async throws -> [TelegramUploadBatchItem]
    func restoreBundle(draft: TelegramPendingUploadDraft) async throws -> TelegramRecoveredUploadBundle
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
    func captureAppend(snapshot: TelegramPendingUploadDraft, additions: [TelegramUploadBatchItem],
                       target: TelegramUploadTarget) async throws -> TelegramUploadAppendCapture {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }
    func installAppend(_ capture: TelegramUploadAppendCapture, target: TelegramUploadTarget) async throws -> TelegramPendingUploadDraft {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }
    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, presentation: TelegramUploadPresentation,
                 target: TelegramUploadTarget, captionInput: TelegramComposerInput, captionAboveMedia: Bool = false,
                 mediaSpoiler: Bool = false, originalDraft: TelegramComposerDraft?, captionPolicy: TelegramUploadCaptionPolicy?) async throws {
        guard captionPolicy == nil else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        try await prepare(preparationID: preparationID, items: items, isGrouped: isGrouped, presentation: presentation,
            target: target, captionInput: captionInput, captionAboveMedia: captionAboveMedia,
            mediaSpoiler: mediaSpoiler, originalDraft: originalDraft)
    }
    func loadArchiveCapture(chatID: Int64) async throws -> TelegramPendingUploadArchiveCapture? {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }
    func installArchive(preparationID: UUID, expectedRevision: UUID, archive: TelegramPendingUploadArchive,
                        target: TelegramUploadTarget, admission: TelegramPendingUploadArchiveAdmission) async throws -> TelegramPendingUploadDraft {
        throw TelegramPendingUploadPersistenceError.incompatibleData
    }

    func restoreBundle(draft: TelegramPendingUploadDraft) async throws -> TelegramRecoveredUploadBundle {
        try Task.checkCancellation()
        guard draft.isValid, draft.accountID == accountID, draft.archive == nil else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        let items = try await restoreItems(draft: draft)
        do {
            try Task.checkCancellation()
            return .init(items: items, archive: nil)
        } catch {
            items.forEach { try? $0.discard() }
            throw error
        }
    }
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
        guard draft.resourceSchemaVersion < 6 else { throw TelegramPendingUploadPersistenceError.incompatibleData }
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
