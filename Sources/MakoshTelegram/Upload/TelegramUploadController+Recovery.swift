import Foundation
import MakoshCore

/// Durable preparation, cancellation and restart recovery.
extension TelegramUploadController {
    func persistInitial(
        file: TelegramUploadFile, target: TelegramUploadTarget, input: TelegramComposerInput,
        original: TelegramComposerDraft?, id: UUID, bound: UUID, store: (any TelegramUploadRecoveryStore)?, above: Bool, spoiler: Bool,
        batchItems: [TelegramUploadBatchItem]? = nil, grouped: Bool = false, frozenPolicy: TelegramUploadCaptionPolicy? = nil
    ) {
        guard let store, store.accountID == target.accountID else {
            recoveryPrepared = false
            recoveryStatus = "Настройте хранилище вложений для сохранения перед отправкой."
            recoveryRetry = nil
            return
        }
        isRecoveryBusy = true
        recoveryInitialInFlight = true
        recoveryRetry = nil
        let discard = self.discard, cancellationPresentation = cancellationPresentationID, batchPresentation = presentation
        let staged = batchItems ?? [.init(id: file.id, file: file)]
        let policy = frozenPolicy ?? captionPolicy
        Task { [weak self] in
            do {
                if let batchItems {
                    try await store.prepare(
                        preparationID: id, items: batchItems, isGrouped: grouped, presentation: batchPresentation, target: target,
                        captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, originalDraft: original, captionPolicy: policy
                    )
                } else {
                    try await store.prepare(
                        preparationID: id, file: file, target: target, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler,
                        originalDraft: original)
                }
                var boundPolicy: TelegramUploadCaptionPolicy?
                if let policy {
                    guard let saved = try await store.load(chatID: target.chatID), saved.isValid, saved.id == id,
                        saved.accountID == target.accountID, saved.chatID == target.chatID,
                        saved.captionRules == (TelegramUploadCaptionRules.containsCustomEmoji(input.formattedText) ? .extended : .current),
                        saved.items.map(\.id) == staged.map(\.id),
                        saved.captionPolicy == (try policy.binding(staged))
                    else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                    boundPolicy = saved.captionPolicy
                }
                if let cancelled = self?.cancelledRecoveryContents.removeValue(forKey: id) {
                    self?.persistCancellation(
                        store: store, id: id, chatID: target.chatID, input: cancelled.input, bound: bound, above: cancelled.above,
                        spoiler: cancelled.spoiler, presentation: cancellationPresentation)
                }
                self?.persistDetachedInitialIfNeeded(store: store, id: id, chatID: target.chatID)
                guard let self, self.bindingID == bound, self.preparationID == id else {
                    for item in staged { try? item.discard(using: discard) }
                    return
                }
                self.captionPolicy = boundPolicy
                self.recoveryInitialInFlight = false
                self.isRecoveryBusy = false
                self.recoveryPrepared = true
                self.recoveryStatus = nil
                if self.captionInput != input || self.captionAboveMedia != above || self.mediaSpoiler != spoiler { self.persistCaption() }
            } catch {
                if let cancelled = self?.cancelledRecoveryContents.removeValue(forKey: id) {
                    self?.persistCancellation(
                        store: store, id: id, chatID: target.chatID, input: cancelled.input, bound: bound, above: cancelled.above,
                        spoiler: cancelled.spoiler, presentation: cancellationPresentation)
                }
                self?.persistDetachedInitialIfNeeded(store: store, id: id, chatID: target.chatID)
                guard let self, self.bindingID == bound, self.preparationID == id else {
                    for item in staged { try? item.discard(using: discard) }
                    return
                }
                self.recoveryInitialInFlight = false
                self.isRecoveryBusy = false
                self.recoveryPrepared = false
                self.recoveryStatus = "Не удалось сохранить вложение. Отправка заблокирована."
                self.recoveryRetry = { [weak self] in
                    self?.persistInitial(
                        file: file, target: target, input: input, original: original, id: id, bound: bound, store: store, above: above,
                        spoiler: spoiler, batchItems: batchItems, grouped: grouped, frozenPolicy: policy)
                }
            }
        }
    }

    func persistCaption() {
        guard appendOperationID == nil, let store = recoveryStore, recoveryPrepared, let id = preparationID, let target, phase == .ready
        else { return }
        let bound = bindingID, input = captionInput, above = captionAboveMedia, spoiler = mediaSpoiler, coverRevision = videoCoverRevision,
            itemRevision = itemsRevision
        Task { [weak self] in
            guard self?.appendOperationID == nil, self?.bindingID == bound, self?.preparationID == id, self?.phase == .ready,
                self?.itemsRevision == itemRevision, self?.captionInput == input, self?.captionAboveMedia == above,
                self?.mediaSpoiler == spoiler
            else { return }
            do {
                try await store.save(
                    preparationID: id, chatID: target.chatID, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler,
                    disposition: .prepared)
                if self?.captionRules == .extended {
                    guard let saved = try await store.load(chatID: target.chatID), saved.isValid,
                        saved.id == id, saved.accountID == target.accountID, saved.chatID == target.chatID,
                        saved.threadID == target.selectedThreadID, saved.captionRules == .extended,
                        saved.captionInput == input, saved.captionAboveMedia == above, saved.mediaSpoiler == spoiler
                    else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                }
                guard let self, self.appendOperationID == nil, self.bindingID == bound, self.preparationID == id,
                    self.itemsRevision == itemRevision, self.videoCoverRevision == coverRevision, self.captionInput == input,
                    self.captionAboveMedia == above, self.mediaSpoiler == spoiler, self.phase == .ready
                else { return }
                self.recoveryStatus = nil
                self.recoveryRetry = nil
            } catch {
                guard let self, self.appendOperationID == nil, self.bindingID == bound, self.preparationID == id,
                    self.itemsRevision == itemRevision, self.videoCoverRevision == coverRevision, self.captionInput == input,
                    self.captionAboveMedia == above, self.mediaSpoiler == spoiler, self.phase == .ready
                else { return }
                self.recoveryStatus = "Не удалось сохранить подпись. Повторите сохранение перед отправкой."
                self.recoveryRetry = { [weak self] in self?.persistCaption() }
            }
        }
    }

    func persistDetachedInitialIfNeeded(store: any TelegramUploadRecoveryStore, id: UUID, chatID: Int64) {
        guard let content = detachedInitialContents.removeValue(forKey: id) else { return }
        persistDetachedPreparation(
            store: store, id: id, chatID: chatID, input: content.input, above: content.above, spoiler: content.spoiler)
    }

    func persistDetachedPreparation(
        store: any TelegramUploadRecoveryStore, id: UUID, chatID: Int64,
        input: TelegramComposerInput, above: Bool, spoiler: Bool
    ) {
        guard detachedRecoveryWrites.insert(id).inserted else { return }
        recoveryRestoreEpoch = UUID()
        detachedRecoveryRetries.removeValue(forKey: id)
        updateDetachedRecoveryStatus()
        Task { [weak self] in
            do {
                try await store.save(
                    preparationID: id, chatID: chatID, captionInput: input,
                    captionAboveMedia: above, mediaSpoiler: spoiler, disposition: .prepared)
            } catch {
                self?.detachedRecoveryRetries[id] = { [weak self] in
                    self?.persistDetachedPreparation(store: store, id: id, chatID: chatID, input: input, above: above, spoiler: spoiler)
                }
            }
            self?.recoveryRestoreEpoch = UUID()
            self?.detachedRecoveryWrites.remove(id)
            self?.updateDetachedRecoveryStatus()
        }
    }

    func updateDetachedRecoveryStatus() {
        detachedRecoveryStatus =
            !detachedRecoveryRetries.isEmpty
            ? "Не удалось сохранить параметры предыдущего вложения. Повторите сохранение."
            : !detachedRecoveryWrites.isEmpty ? "Сохраняем параметры предыдущего вложения…" : nil
    }

    func resetCancellationPresentation() {
        cancellationPresentationID = UUID()
        cancellationStatus = nil
        cancellationRetry = nil
        isCancellationBusy = false
    }

    func tombstoneKnownUnsent() {
        guard let store = recoveryStore, let id = preparationID, let target else { return }
        // The initial write may commit even when its acknowledgement fails. Wait
        // for its completion before publishing the cancellation marker.
        if recoveryInitialInFlight {
            cancelledRecoveryContents[id] = (captionInput, captionAboveMedia, mediaSpoiler)
            return
        }
        persistCancellation(
            store: store, id: id, chatID: target.chatID, input: captionInput, bound: bindingID, above: captionAboveMedia,
            spoiler: mediaSpoiler)
    }

    func persistCancellation(
        store: any TelegramUploadRecoveryStore, id: UUID,
        chatID: Int64, input: TelegramComposerInput, bound: UUID, above: Bool, spoiler: Bool, presentation: UUID? = nil
    ) {
        guard cancellationStarted.insert(id).inserted else { return }
        if let write = videoCoverWrites[id] {
            detachedRecoveryRetries.removeValue(forKey: id)
            // Running writes keep their candidate until their actual completion.
            if !write.isRunning { videoCoverWrites.removeValue(forKey: id) }
            if bindingID == bound, preparationID == id { recoveryRetry = nil }
            updateDetachedRecoveryStatus()
        }
        if presentationWrites.removeValue(forKey: id) != nil {
            detachedRecoveryRetries.removeValue(forKey: id)
            if bindingID == bound, preparationID == id { recoveryRetry = nil }
            // An in-flight CAS still owns its marker until its callback finishes.
            updateDetachedRecoveryStatus()
        }
        let presentation = presentation ?? cancellationPresentationID
        writeCancellation(
            store: store, id: id, chatID: chatID, input: input, bound: bound, above: above, spoiler: spoiler, presentation: presentation)
    }

    func writeCancellation(
        store: any TelegramUploadRecoveryStore, id: UUID,
        chatID: Int64, input: TelegramComposerInput, bound: UUID, above: Bool, spoiler: Bool, presentation: UUID
    ) {
        let current = bindingID == bound && cancellationPresentationID == presentation
        if current {
            isCancellationBusy = true
            cancellationRetry = nil
        }
        Task { [weak self] in
            do {
                try await store.save(
                    preparationID: id, chatID: chatID, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler,
                    disposition: .cancelled)
                guard let self, self.bindingID == bound, self.cancellationPresentationID == presentation else { return }
                self.isCancellationBusy = false
                self.cancellationStatus = nil
                self.cancellationRetry = nil
            } catch {
                guard let self, self.bindingID == bound, self.cancellationPresentationID == presentation else { return }
                self.isCancellationBusy = false
                self.cancellationStatus = "Не удалось подтвердить отмену сохранённого вложения. Повторите сохранение отмены."
                self.cancellationRetry = { [weak self] in
                    self?.writeCancellation(
                        store: store, id: id, chatID: chatID, input: input, bound: bound, above: above, spoiler: spoiler,
                        presentation: presentation)
                }
            }
        }
    }

    func persistAcceptance(
        store: any TelegramUploadRecoveryStore, id: UUID, target: TelegramUploadTarget,
        input: TelegramComposerInput, localMessageID: String, bound: UUID, above: Bool, spoiler: Bool
    ) {
        isRecoveryBusy = true
        recoveryRetry = nil
        Task { [weak self] in
            do {
                try await store.save(
                    preparationID: id, chatID: target.chatID, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler,
                    disposition: .accepted(localMessageID: localMessageID))
                guard let self, self.bindingID == bound, self.preparationID == id, self.messageID == localMessageID else { return }
                self.isRecoveryBusy = false
                self.recoveryStatus = nil
                self.acknowledgeAccepted()
            } catch {
                guard let self, self.bindingID == bound, self.preparationID == id, self.messageID == localMessageID else { return }
                self.isRecoveryBusy = false
                self.phase = .uncertain
                self.recoveryStatus = "Очередь приняла вложение, но сохранить подтверждение не удалось. Повтор отправки запрещён."
                self.recoveryRetry = { [weak self] in
                    self?.persistAcceptance(
                        store: store, id: id, target: target, input: input, localMessageID: localMessageID, bound: bound, above: above,
                        spoiler: spoiler)
                }
            }
        }
    }

    func acknowledgeAccepted() {
        guard acceptancePending else { return }
        acceptancePending = false
        phase = .queued(nil)
        error = nil
        cleanup()
        let id = preparationID
        if let target { didQueue?(target, sentCaption) }
        if preparationID == id { finishPreparation() }
    }

    @discardableResult func releaseStage() -> Bool {
        videoPlayback.stop()
        if recoveryInitialInFlight {
            file = nil
            recoveryInitialInFlight = false
            return true
        }
        return cleanup()
    }

    @discardableResult
    func restore(
        draft: TelegramPendingUploadDraft, bundle: TelegramRecoveredUploadBundle, target: TelegramUploadTarget, restorationEpoch: UUID,
        admission: @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard draft.isValid else { return false }
        let items = bundle.items
        if draft.resourceSchemaVersion < 6 {
            guard bundle.archive == nil, items.count == 1, items[0].id == draft.items[0].id else { return false }
            return await restore(
                draft: draft, file: items[0].file, target: target, restorationEpoch: restorationEpoch, admission: admission)
        }
        guard restorationEpoch == recoveryRestoreEpoch, phase == .idle, self.items.isEmpty, recoveredArchive == nil,
            (6...19).contains(draft.resourceSchemaVersion),
            provider is any TelegramUploadBatchProvider, provider?.accountID == draft.accountID,
            recoveryStore?.accountID == draft.accountID, target.accountID == draft.accountID, target.chatID == draft.chatID,
            target.selectedThreadID == draft.threadID,
            target.hasValidReplySource, detachedInitialContents[draft.id] == nil,
            !detachedRecoveryWrites.contains(draft.id), detachedRecoveryRetries[draft.id] == nil,
            admission()
        else { return false }
        let bound = bindingID, request = token, revision = itemsRevision, validate = willValidateUpload
        let valid = try? await BackgroundWork.run {
            try validate?()
            return Self.matchesItems(items, draft: draft)
                && (draft.archive != nil
                    ? Self.matchesArchive(bundle.archive, draft: draft)
                    : !draft.hasArchiveSchema && bundle.archive == nil)
        }
        guard valid == true, !Task.isCancelled, admission(), bindingID == bound, token == request, itemsRevision == revision,
            restorationEpoch == recoveryRestoreEpoch, phase == .idle, self.items.isEmpty, recoveredArchive == nil,
            provider is any TelegramUploadBatchProvider, provider?.accountID == draft.accountID,
            recoveryStore?.accountID == draft.accountID, detachedInitialContents[draft.id] == nil,
            !detachedRecoveryWrites.contains(draft.id), detachedRecoveryRetries[draft.id] == nil
        else { return false }
        switch draft.disposition {
        case .prepared:
            guard draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else { return false }
        case .submissionStarted: break
        case .accepted, .acceptedBatch, .cancelled: return false
        }
        token = UUID()
        preparationID = draft.id
        self.items = items
        selectedItemID = items[0].id
        recoveredArchive = bundle.archive
        archiveDescriptor = draft.archive
        usesBatchRecovery = true
        captionRules = draft.captionRules
        captionPolicy = draft.captionPolicy
        mediaRules = draft.mediaRules
        isGrouped = draft.isGrouped
        presentation = draft.presentation
        itemsRevision = UUID()
        self.target = target
        captionInput = draft.captionInput
        captionAboveMedia = draft.captionAboveMedia
        mediaSpoiler = draft.mediaSpoiler
        captionRevision = UUID()
        sentInput = draft.captionInput
        sentCaption = draft.captionInput.formattedText
        sentCaptionAboveMedia = draft.captionAboveMedia
        sentMediaSpoiler = draft.mediaSpoiler
        recoveryPrepared = true
        committed = draft.disposition == .submissionStarted
        phase = committed ? .uncertain : .ready
        didRestore?(target, draft.originalDraft, draft.id)
        return true
    }

    nonisolated static func matchesItems(_ items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft) -> Bool {
        items.count == draft.items.count
            && zip(items, draft.items).allSatisfy({ staged, saved in
                staged.id == saved.id && staged.file.name.utf8.elementsEqual(saved.file.attachment.name.utf8)
                    && staged.file.size == saved.file.plaintextByteCount && staged.file.mode.rawValue == saved.file.attachment.kind
                    && staged.file.video == saved.video && telegramPendingUploadCoverMatches(saved.videoCover, staged.file.videoCover)
                    && staged.file.metadata == saved.metadata && staged.sourceFacts == saved.sourceFacts
                    && saved.matchesOriginal(staged.originalFile) && (try? TelegramUploadFileIO.validateOwnedStage(staged.file)) != nil
                    && (staged.file.videoCover == nil || (try? TelegramUploadVideoCoverIO.validatedBytes(staged.file.videoCover!)) != nil)
            })
    }

    nonisolated static func matchesArchive(_ value: TelegramUploadArchiveIO.Archive?, draft: TelegramPendingUploadDraft) -> Bool {
        guard draft.hasArchiveSchema, let descriptor = draft.archive, let archive = value,
            archive.file.name.utf8.elementsEqual(descriptor.file.attachment.name.utf8),
            archive.file.size == descriptor.file.plaintextByteCount, archive.file.mode == .file,
            archive.file.video == nil, archive.file.videoCover == nil, archive.file.metadata == nil,
            archive.file.pixelWidth == nil, archive.file.pixelHeight == nil,
            (try? TelegramUploadFileIO.validateOwnedStage(archive.file)) != nil,
            archive.members.count == descriptor.members.count,
            zip(archive.members, zip(descriptor.members, draft.items)).allSatisfy({ member, saved in
                let raw = saved.1.originalFile ?? saved.1.file
                return member.itemID == saved.0.itemID && member.itemID == saved.1.id
                    && member.entryName.utf8.elementsEqual(saved.0.entryName.utf8)
                    && member.sourceName.utf8.elementsEqual(raw.attachment.name.utf8) && member.byteCount == raw.plaintextByteCount
                    && member.plaintextSHA256 == raw.plaintextSHA256
            })
        else { return false }
        return true
    }

    @discardableResult
    func restore(
        draft: TelegramPendingUploadDraft, items: [TelegramUploadBatchItem], target: TelegramUploadTarget, restorationEpoch: UUID
    ) async -> Bool {
        guard draft.archive == nil else { return false }
        return await restore(draft: draft, bundle: .init(items: items, archive: nil), target: target, restorationEpoch: restorationEpoch)
    }

    @discardableResult
    func restore(
        draft: TelegramPendingUploadDraft, file: TelegramUploadFile, target: TelegramUploadTarget, restorationEpoch: UUID,
        admission: @MainActor () -> Bool = { true }
    ) async -> Bool {
        // A load/file export may finish after a detached write has cleared its
        // pending marker. Only a snapshot begun in the current epoch can apply.
        guard restorationEpoch == recoveryRestoreEpoch, phase == .idle, items.isEmpty, recoveredArchive == nil,
            draft.isValid, draft.resourceSchemaVersion < 6, file.metadata == nil,
            provider?.accountID == draft.accountID,
            detachedInitialContents[draft.id] == nil, !detachedRecoveryWrites.contains(draft.id), detachedRecoveryRetries[draft.id] == nil,
            recoveryStore?.accountID == draft.accountID, target.accountID == draft.accountID,
            target.chatID == draft.chatID, target.selectedThreadID == draft.threadID, target.hasValidReplySource,
            file.name == draft.file.attachment.name, file.size == draft.file.plaintextByteCount,
            file.mode.rawValue == draft.file.attachment.kind, file.video == draft.video,
            telegramPendingUploadCoverMatches(draft.videoCover, file.videoCover), admission()
        else { return false }
        let bound = bindingID, request = token, revision = itemsRevision, validate = willValidateUpload
        do {
            try await BackgroundWork.run {
                try validate?()
                try TelegramUploadFileIO.validateOwnedStage(file)
                if let cover = file.videoCover { _ = try TelegramUploadVideoCoverIO.validatedBytes(cover) }
            }
        } catch { return false }
        guard !Task.isCancelled, admission(), bindingID == bound, token == request, itemsRevision == revision,
            restorationEpoch == recoveryRestoreEpoch, phase == .idle, items.isEmpty, recoveredArchive == nil,
            provider?.accountID == draft.accountID, recoveryStore?.accountID == draft.accountID,
            detachedInitialContents[draft.id] == nil, !detachedRecoveryWrites.contains(draft.id),
            detachedRecoveryRetries[draft.id] == nil
        else { return false }
        switch draft.disposition {
        case .prepared:
            guard draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else { return false }
        case .submissionStarted: break  // Missing reply cannot authorize any new submit.
        case .accepted, .acceptedBatch, .cancelled: return false
        }
        token = UUID()
        preparationID = draft.id
        self.file = file
        self.target = target
        captionInput = draft.captionInput
        captionAboveMedia = draft.captionAboveMedia
        captionRevision = UUID()
        sentCaptionAboveMedia = draft.captionAboveMedia
        mediaSpoiler = draft.mediaSpoiler
        sentMediaSpoiler = draft.mediaSpoiler
        recoveryPrepared = true
        committed = false
        sentCaption = draft.captionInput.formattedText
        if case .submissionStarted = draft.disposition {
            phase = .uncertain
            committed = true
        } else {
            phase = .ready
        }
        didRestore?(target, draft.originalDraft, draft.id)
        return true
    }

    func finishPreparation() {
        guard let id = preparationID else { return }
        preparationID = nil
        didFinishPreparation?(id)
    }

    nonisolated static func excludingRetainedCover(_ file: TelegramUploadFile, retained: Set<UUID>) -> TelegramUploadFile {
        guard let cover = file.videoCover, retained.contains(cover.id) else { return file }
        return TelegramUploadFile(
            id: file.id, name: file.name, size: file.size, mode: file.mode,
            pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: file.url, directory: file.directory,
            video: file.video, videoCover: nil, metadata: file.metadata)
    }

    @discardableResult func cleanup() -> Bool {
        videoPlayback.stop()
        let retained = Set(videoCoverWrites.values.compactMap { $0.cover?.id })
        for write in videoCoverWrites.values { write.detached = true }
        let discard = self.discard
        var failed: [TelegramUploadBatchItem] = []
        for item in items + retiredItems {
            do { try item.discard(using: { try discard(Self.excludingRetainedCover($0, retained: retained)) }) } catch {
                failed.append(item)
            }
        }
        items = failed
        retiredItems = []
        if let recoveredArchive {
            do {
                try discard(recoveredArchive.file)
                self.recoveredArchive = nil
                archiveDescriptor = nil
            } catch { self.error = "Не удалось удалить временный файл." }
        }
        if !items.contains(where: { $0.id == selectedItemID }) { selectedItemID = items.first?.id }
        if !failed.isEmpty { self.error = "Не удалось удалить временный файл." }
        return failed.isEmpty && recoveredArchive == nil
    }
}
