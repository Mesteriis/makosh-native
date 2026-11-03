import Foundation
import MakoshCore

/// Video cover editing, persistence and previews.
extension TelegramUploadController {
    public var isVideoCoverSaving: Bool { videoCoverWriteRevision != nil }

    public var canEditVideoCover: Bool {
        phase == .ready && file?.mode == .video && file?.metadata?.gif == nil && !containsRecordedRoundVideo && target != nil
            && provider?.accountID == target?.accountID && videoCoverEditingID == nil && !isVideoCoverSaving && !isRecoveryBusy
            && (recoveryStore == nil ? !requiresRecovery : recoveryPrepared && recoveryStore?.accountID == target?.accountID)
    }

    public func beginVideoCoverEdit(contextID: UUID, revision: UUID) -> UUID? {
        guard preparationID == contextID, videoCoverRevision == revision, canEditVideoCover else { return nil }
        videoPlayback.stop()
        let id = UUID()
        videoCoverEditingID = id
        return id
    }

    public func cancelVideoCoverEdit(_ editID: UUID) {
        guard videoCoverEditingID == editID else { return }
        videoCoverEditingID = nil
        videoCoverRevision = UUID()
    }

    /// A true return transfers ownership of the new cover to this preparation.
    @discardableResult public func commitVideoCover(_ cover: TelegramUploadVideoCover?, editID: UUID) async -> Bool {
        guard videoCoverEditingID == editID, phase == .ready, !isRecoveryBusy,
            let id = preparationID, let original = file, original.mode == .video, original.metadata?.roundVideo == nil,
            let target, provider?.accountID == target.accountID,
            recoveryStore == nil ? !requiresRecovery : recoveryPrepared && recoveryStore?.accountID == target.accountID
        else { return false }
        let bound = bindingID, request = token, revision = videoCoverRevision, itemRevision = itemsRevision
        let itemID = selectedItemID, validate = willValidateUpload
        @MainActor func current() -> Bool {
            !Task.isCancelled && bindingID == bound && token == request && preparationID == id && videoCoverEditingID == editID
                && videoCoverRevision == revision && itemsRevision == itemRevision && selectedItemID == itemID && file == original
                && self.target == target && phase == .ready && !isRecoveryBusy && provider?.accountID == target.accountID
                && (recoveryStore == nil ? !requiresRecovery : recoveryPrepared && recoveryStore?.accountID == target.accountID)
        }
        do {
            try await BackgroundWork.run {
                try validate?()
                if let cover {
                    guard cover.id != original.id else { throw TelegramUploadFileError.unavailable }
                    _ = try TelegramUploadVideoCoverIO.validatedBytes(cover)
                }
            }
        } catch {
            if current() { self.error = "Не удалось применить обложку. Выберите изображение заново." }
            return false
        }
        guard current() else { return false }
        videoCoverEditingID = nil
        videoCoverRevision = UUID()
        videoPlayback.stop()
        error = nil
        file = TelegramUploadFile(
            id: original.id, name: original.name, size: original.size, mode: original.mode,
            pixelWidth: original.pixelWidth, pixelHeight: original.pixelHeight, url: original.url, directory: original.directory,
            video: original.video, videoCover: cover, metadata: original.metadata)
        if let old = original.videoCover, old.id != cover?.id {
            do { try discard(old.imageFile) } catch { self.error = "Не удалось удалить временную копию предыдущей обложки." }
        }
        if let store = recoveryStore {
            videoCoverWriteRevision = videoCoverRevision
            persistVideoCover(
                store: store, original: original, cover: cover, target: target,
                id: id, bound: bindingID, revision: videoCoverRevision, itemID: usesBatchRecovery ? selectedItemID : nil)
        }
        return true
    }

    func isCurrent(_ write: VideoCoverWrite) -> Bool {
        bindingID == write.binding && preparationID == write.id && videoCoverWriteRevision == write.revision && phase == .ready
    }

    func persistVideoCover(
        store: any TelegramUploadRecoveryStore, original: TelegramUploadFile,
        cover: TelegramUploadVideoCover?, target: TelegramUploadTarget,
        id: UUID, bound: UUID, revision: UUID, itemID: UUID?
    ) {
        guard bindingID == bound, preparationID == id, videoCoverWriteRevision == revision, phase == .ready else { return }
        let write = VideoCoverWrite(
            store: store, original: original, cover: cover, target: target, id: id,
            binding: bound, revision: revision, itemID: itemID, input: captionInput, above: captionAboveMedia, spoiler: mediaSpoiler)
        // Register ownership synchronously, before the task's first opportunity to suspend.
        videoCoverWrites[id] = write
        persistVideoCover(write)
    }

    func persistVideoCover(_ write: VideoCoverWrite) {
        guard videoCoverWrites[write.id] === write, !write.isRunning, !cancellationStarted.contains(write.id) else { return }
        write.isRunning = true
        detachedRecoveryWrites.insert(write.id)
        detachedRecoveryRetries.removeValue(forKey: write.id)
        recoveryRestoreEpoch = UUID()
        if isCurrent(write) {
            isRecoveryBusy = true
            recoveryPrepared = false
            recoveryRetry = nil
            recoveryStatus = "Сохраняем обложку…"
        } else {
            updateDetachedRecoveryStatus()
        }
        Task { [weak self, write] in
            do {
                if let itemID = write.itemID {
                    try await write.store.replaceVideoCover(
                        preparationID: write.id, itemID: itemID, file: write.original,
                        target: write.target, cover: write.cover)
                } else {
                    try await write.store.replaceVideoCover(
                        preparationID: write.id, file: write.original,
                        target: write.target, cover: write.cover)
                }
                // Confirm the visible caption/options too before sending can resume.
                try await write.store.save(
                    preparationID: write.id, chatID: write.target.chatID, captionInput: write.input,
                    captionAboveMedia: write.above, mediaSpoiler: write.spoiler, disposition: .prepared)
                guard let self, self.videoCoverWrites[write.id] === write else { return }
                let current = self.isCurrent(write)
                self.videoCoverWrites.removeValue(forKey: write.id)
                self.detachedRecoveryWrites.remove(write.id)
                self.detachedRecoveryRetries.removeValue(forKey: write.id)
                self.recoveryRestoreEpoch = UUID()
                write.isRunning = false
                if current {
                    self.videoCoverWriteRevision = nil
                    self.isRecoveryBusy = false
                    self.recoveryPrepared = true
                    self.recoveryStatus = nil
                    self.recoveryRetry = nil
                }
                self.updateDetachedRecoveryStatus()
            } catch {
                guard let self, self.videoCoverWrites[write.id] === write else { return }
                write.isRunning = false
                self.detachedRecoveryWrites.remove(write.id)
                self.recoveryRestoreEpoch = UUID()
                if self.cancellationStarted.contains(write.id) {
                    self.videoCoverWrites.removeValue(forKey: write.id)
                    self.detachedRecoveryRetries.removeValue(forKey: write.id)
                } else if self.isCurrent(write) {
                    self.isRecoveryBusy = false
                    self.recoveryPrepared = false
                    self.recoveryStatus = "Не удалось подтвердить сохранение обложки. Повторите сохранение перед отправкой."
                    self.recoveryRetry = { [weak self, write] in self?.persistVideoCover(write) }
                } else {
                    self.detachedRecoveryRetries[write.id] = { [weak self, write] in self?.persistVideoCover(write) }
                }
                self.updateDetachedRecoveryStatus()
            }
        }
    }

    public func openVideoPreview(contextID: UUID) async {
        guard preparationID == contextID, phase == .ready, !mediaSpoiler, videoCoverEditingID == nil, !isVideoCoverSaving,
            let file, file.mode == .video, file.metadata?.roundVideo == nil, file.videoCover == nil
        else { return }
        await videoPlayback.load(file)
    }

    /// Explicit round preparation keeps the ordinary-video preview boundary closed.
    public func openRoundVideoPreview(contextID: UUID) async {
        guard preparationID == contextID, phase == .ready, containsRecordedRoundVideo,
            items.count == 1, presentation == .media, !mediaSpoiler,
            videoCoverEditingID == nil, !isVideoCoverSaving,
            let file, file.metadata?.roundVideo != nil, file.videoCover == nil
        else { return }
        await videoPlayback.loadRoundVideo(file)
    }

    public func stopVideoPreview(contextID: UUID) {
        guard preparationID == contextID else { return }
        videoPlayback.stop()
    }
}
