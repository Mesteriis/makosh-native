import Foundation
import MakoshCore

/// Presentation modes (media/file/archive) and their durable writes.
extension TelegramUploadController {
    var containsRecordedVoice: Bool {
        preparingRecordedVoice || items.contains(where: { $0.file.metadata?.voice != nil })
    }

    var containsRecordedRoundVideo: Bool {
        preparingRecordedRoundVideo || items.contains(where: { $0.file.metadata?.roundVideo != nil })
    }

    var containsRecordedMedia: Bool { containsRecordedVoice || containsRecordedRoundVideo }

    public var canEditItems: Bool {
        usesBatchRecovery && presentation != .archive && !containsRecordedRoundVideo && phase == .ready && recoveryPrepared
            && !isRecoveryBusy && videoCoverEditingID == nil && !isVideoCoverSaving
    }

    public var isVisualMedia: Bool {
        !containsRecordedRoundVideo && presentation == .media && !items.isEmpty && items.allSatisfy { $0.file.mode != .file }
    }

    public var canUseMediaOptions: Bool {
        !containsRecordedRoundVideo && presentation == .media && items.contains { $0.file.mode != .file }
    }

    public var canSwitchPresentation: Bool {
        usesBatchRecovery && !containsRecordedMedia && TelegramUploadBatchItem.allowsMedia(items, rules: mediaRules)
    }

    public var canUseFilePresentation: Bool {
        usesBatchRecovery && !containsRecordedMedia && !items.isEmpty
            && items.allSatisfy { $0.file.mode != .photo || $0.originalFile != nil }
    }

    public var canUseArchivePresentation: Bool {
        usesBatchRecovery && captionRules != .legacy && !containsRecordedMedia
            && (2...TelegramUploadArchiveLimits.members).contains(items.count) && items.allSatisfy { $0.sourceFacts != nil }
    }

    public var canEditPresentation: Bool {
        usesBatchRecovery && !containsRecordedMedia && phase == .ready && recoveryPrepared && !isRecoveryBusy && videoCoverEditingID == nil
            && !isVideoCoverSaving
    }

    public var canGroupItems: Bool {
        !containsRecordedMedia && presentation.allowsGrouping(items)
    }

    public var presentedItems: [TelegramUploadBatchItem] {
        if presentation == .archive, let recoveredArchive, let archiveDescriptor {
            return [.init(id: archiveDescriptor.id, file: recoveredArchive.file)]
        }
        return items.compactMap { $0.presented(as: presentation) }
    }

    @discardableResult public func updatePresentation(_ presentation: TelegramUploadPresentation, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditPresentation else { return false }
        if self.presentation == presentation { return true }
        guard presentation == .archive ? canUseArchivePresentation : presentation == .file ? canUseFilePresentation : canSwitchPresentation
        else { return false }
        let previousPresentation = self.presentation, previousGrouping = isGrouped
        videoPlayback.stop()
        self.presentation = presentation
        if presentation == .archive {
            captionAboveMedia = false
            mediaSpoiler = false
        }
        isGrouped = isGrouped && canGroupItems
        itemsRevision = UUID()
        captionRevision = UUID()
        videoCoverRevision = UUID()
        persistPresentation(previousPresentation: previousPresentation, previousGrouping: previousGrouping)
        return true
    }

    func persistPresentation(previousPresentation: TelegramUploadPresentation, previousGrouping: Bool) {
        guard let store = recoveryStore, let id = preparationID, let target else { return }
        writePresentation(
            .init(
                store: store, id: id, target: target, binding: bindingID, revision: itemsRevision,
                previousIDs: nil, orderedIDs: items.map(\.id), previousPresentation: previousPresentation,
                previousGrouping: previousGrouping,
                presentation: presentation, isGrouped: isGrouped, cachedArchive: archiveDescriptor, captionPolicy: captionPolicy,
                input: captionInput, above: captionAboveMedia, spoiler: mediaSpoiler))
    }

    struct PresentationWrite {
        let store: any TelegramUploadRecoveryStore
        let id: UUID
        let target: TelegramUploadTarget
        let binding: UUID
        let revision: UUID
        let previousIDs: [UUID]?
        let orderedIDs: [UUID]
        let previousPresentation: TelegramUploadPresentation
        let previousGrouping: Bool
        let presentation: TelegramUploadPresentation
        let isGrouped: Bool
        let cachedArchive: TelegramPendingUploadArchive?
        let captionPolicy: TelegramUploadCaptionPolicy?
        var input: TelegramComposerInput
        var above: Bool
        var spoiler: Bool
    }

    func isCurrent(_ write: PresentationWrite) -> Bool {
        bindingID == write.binding && preparationID == write.id && itemsRevision == write.revision && phase == .ready
    }

    func finishPresentationWrite(_ id: UUID) {
        presentationWrites.removeValue(forKey: id)
        detachedRecoveryWrites.remove(id)
        detachedRecoveryRetries.removeValue(forKey: id)
        recoveryRestoreEpoch = UUID()
        updateDetachedRecoveryStatus()
    }

    func writePresentation(_ write: PresentationWrite) {
        guard detachedRecoveryWrites.insert(write.id).inserted else { return }
        presentationWrites[write.id] = write
        recoveryRestoreEpoch = UUID()
        detachedRecoveryRetries.removeValue(forKey: write.id)
        if isCurrent(write) {
            isRecoveryBusy = true
            recoveryPrepared = false
            recoveryRetry = nil
            recoveryStatus = write.previousIDs == nil ? "Сохраняем способ отправки…" : "Сохраняем набор вложений…"
        } else {
            updateDetachedRecoveryStatus()
        }
        Task { [weak self] in
            do {
                if let previousIDs = write.previousIDs {
                    try await write.store.updateItems(
                        preparationID: write.id, previousIDs: previousIDs,
                        previousGrouping: write.previousGrouping, previousPresentation: write.previousPresentation,
                        orderedIDs: write.orderedIDs, isGrouped: write.isGrouped, presentation: write.presentation, target: write.target)
                } else {
                    try await write.store.updatePresentation(
                        preparationID: write.id, orderedIDs: write.orderedIDs,
                        previousPresentation: write.previousPresentation, previousGrouping: write.previousGrouping,
                        presentation: write.presentation, isGrouped: write.isGrouped, target: write.target)
                }
                if let policy = write.captionPolicy {
                    guard let saved = try await write.store.load(chatID: write.target.chatID), saved.isValid,
                        saved.id == write.id, saved.accountID == write.target.accountID,
                        saved.chatID == write.target.chatID, saved.disposition == .prepared,
                        saved.items.map(\.id) == write.orderedIDs, saved.presentation == write.presentation,
                        saved.isGrouped == write.isGrouped, saved.captionPolicy == policy
                    else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                }
                if write.presentation == .archive || write.previousPresentation == .archive || write.cachedArchive != nil {
                    let invalidated = write.previousIDs.map { $0 != write.orderedIDs } ?? false
                    guard let saved = try await write.store.load(chatID: write.target.chatID), saved.isValid,
                        saved.id == write.id, saved.accountID == write.target.accountID,
                        saved.chatID == write.target.chatID, saved.disposition == .prepared,
                        saved.items.map(\.id) == write.orderedIDs, saved.presentation == write.presentation,
                        saved.isGrouped == write.isGrouped
                    else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                    if invalidated {
                        guard saved.archive == nil else { throw TelegramPendingUploadPersistenceError.conflict }
                    } else {
                        guard saved.archive != nil else { throw TelegramPendingUploadPersistenceError.conflict }
                        if let expected = write.cachedArchive {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.sortedKeys]
                            guard try encoder.encode(saved.archive) == encoder.encode(expected) else {
                                throw TelegramPendingUploadPersistenceError.conflict
                            }
                        }
                    }
                    let bundle = try await write.store.restoreBundle(draft: saved)
                    do {
                        let validate = self?.willValidateUpload
                        let valid = try await BackgroundWork.run {
                            try validate?()
                            return saved.archive == nil ? bundle.archive == nil : Self.matchesArchive(bundle.archive, draft: saved)
                        }
                        guard valid else { throw TelegramPendingUploadPersistenceError.incompatibleData }
                        try await Task.detached(priority: .utility) {
                            for item in bundle.items { try item.discard() }
                        }.value
                        if let self, self.isCurrent(write) {
                            if let previous = self.recoveredArchive { try self.discard(previous.file) }
                            self.recoveredArchive = bundle.archive
                            self.archiveDescriptor = saved.archive
                        } else {
                            try await Self.discardBundle(bundle)
                        }
                    } catch {
                        try? await Self.discardBundle(bundle)
                        throw error
                    }
                }
                if let self, self.isCurrent(write) {
                    self.finishPresentationWrite(write.id)
                    self.isRecoveryBusy = false
                    self.recoveryPrepared = true
                    self.recoveryStatus = nil
                    if write.previousIDs != nil {
                        var remaining: [TelegramUploadBatchItem] = []
                        for item in self.retiredItems {
                            do { try item.discard(using: self.discard) } catch {
                                remaining.append(item)
                                self.error = "Не удалось удалить временный файл."
                            }
                        }
                        self.retiredItems = remaining
                    }
                    self.persistCaption()
                } else {
                    // Rebinding may change the input while the original mode/list CAS is held.
                    // Its latest frozen tuple still belongs only to the original store.
                    if self?.cancellationStarted.contains(write.id) != true {
                        let frozen = self?.presentationWrites[write.id] ?? write
                        try await frozen.store.save(
                            preparationID: frozen.id, chatID: frozen.target.chatID,
                            captionInput: frozen.input, captionAboveMedia: frozen.above, mediaSpoiler: frozen.spoiler,
                            disposition: .prepared)
                    }
                    self?.finishPresentationWrite(write.id)
                }
            } catch {
                guard let self else { return }
                let frozen = self.presentationWrites[write.id] ?? write
                self.detachedRecoveryWrites.remove(write.id)
                self.recoveryRestoreEpoch = UUID()
                if self.cancellationStarted.contains(write.id) {
                    self.finishPresentationWrite(write.id)
                } else if self.isCurrent(write) {
                    self.isRecoveryBusy = false
                    self.recoveryStatus =
                        write.previousIDs == nil
                        ? "Не удалось подтвердить способ отправки. Повторите сохранение перед отправкой."
                        : "Не удалось подтвердить сохранение набора. Повторите сохранение перед отправкой."
                    self.recoveryRetry = { [weak self] in self?.writePresentation(frozen) }
                } else {
                    self.presentationWrites.removeValue(forKey: write.id)
                    self.detachedRecoveryRetries[write.id] = { [weak self] in self?.writePresentation(frozen) }
                }
                self.updateDetachedRecoveryStatus()
            }
        }
    }
}
