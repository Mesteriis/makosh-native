import Foundation
import UniformTypeIdentifiers

/// Dispatching prepared uploads and observing acceptance.
extension TelegramUploadController {
    public func send(contextID: UUID) {
        guard preparationID == contextID else { return }
        send()
    }

    public func sendAsSpoiler(contextID: UUID, revision: UUID) {
        guard preparationID == contextID, captionRevision == revision,
            canUseMediaOptions, canSend
        else { return }
        send(spoilerOverride: true)
    }

    public func dismissPreparation(contextID: UUID) {
        guard preparationID == contextID else { return }
        if canCancel {
            cancelPreparation()
            clear()
        } else if phase == .uncertain {
            clear()
        }
    }

    public func send() { send(spoilerOverride: nil) }

    func send(spoilerOverride: Bool?) {
        guard captionRules.canSend(captionInput.formattedText, maximumUTF16Count: captionMaximumUTF16Count) else {
            error = "Подпись или её форматирование не поддерживаются. Максимум — \(captionMaximumUTF16Count) знака UTF16."
            return
        }
        guard canSend, let provider, let file, let target else { return }
        videoPlayback.stop()
        let frozen = captionInput, frozenAbove = captionAboveMedia, frozenSpoiler = spoilerOverride ?? mediaSpoiler
        let bundle = usesBatchRecovery ? TelegramRecoveredUploadBundle(items: items, archive: recoveredArchive) : nil
        let grouped = isGrouped, presentation = self.presentation, descriptor = archiveDescriptor, rules = captionRules,
            frozenPolicy = captionPolicy, frozenMediaRules = mediaRules
        if let store = recoveryStore, let id = preparationID {
            let bound = bindingID
            isRecoveryBusy = true
            recoveryRetry = nil
            phase = .storing
            Task { [weak self] in
                guard self?.bindingID == bound, self?.preparationID == id, self?.phase == .storing else { return }
                do {
                    try await store.save(
                        preparationID: id, chatID: target.chatID, captionInput: frozen, captionAboveMedia: frozenAbove,
                        mediaSpoiler: frozenSpoiler, disposition: .submissionStarted)
                    if let bundle {
                        guard let batchProvider = provider as? any TelegramUploadBatchProvider,
                            let draft = try await store.load(chatID: target.chatID), draft.isValid,
                            (6...19).contains(draft.resourceSchemaVersion), draft.archive == descriptor, draft.captionRules == rules,
                            draft.captionPolicy == frozenPolicy, draft.mediaRules == frozenMediaRules,
                            draft.id == id, draft.disposition == .submissionStarted,
                            draft.items.map(\.id) == bundle.items.map(\.id), draft.isGrouped == grouped, draft.presentation == presentation,
                            draft.items.map(\.sourceFacts) == bundle.items.map(\.sourceFacts),
                            draft.captionInput == frozen, draft.captionAboveMedia == frozenAbove, draft.mediaSpoiler == frozenSpoiler
                        else {
                            throw TelegramPendingUploadPersistenceError.conflict
                        }
                        guard let self, self.bindingID == bound, self.preparationID == id, self.phase == .storing else { return }
                        self.isRecoveryBusy = false
                        self.dispatchBatch(provider: batchProvider, store: store, bundle: bundle, draft: draft, target: target)
                        return
                    }
                    guard let self, self.bindingID == bound, self.preparationID == id, self.phase == .storing else { return }
                    self.isRecoveryBusy = false
                    self.dispatch(
                        provider: provider, file: file, target: target, frozen: frozen, above: frozenAbove, spoiler: frozenSpoiler)
                } catch {
                    guard let self, self.bindingID == bound, self.preparationID == id, self.phase == .storing else { return }
                    // A failed write acknowledgement may have committed the marker.
                    // Retry only persistence, never submit through this failure path.
                    self.isRecoveryBusy = false
                    self.phase = .uncertain
                    self.recoveryStatus = "Не удалось подтвердить сохранение начала отправки. Автоматического повтора нет."
                }
            }
        } else if !requiresRecovery && !usesBatchRecovery {
            dispatch(provider: provider, file: file, target: target, frozen: frozen, above: frozenAbove, spoiler: frozenSpoiler)
        }
    }

    func dispatchBatch(
        provider: any TelegramUploadBatchProvider, store: any TelegramUploadRecoveryStore,
        bundle: TelegramRecoveredUploadBundle, draft: TelegramPendingUploadDraft, target: TelegramUploadTarget
    ) {
        let request = UUID()
        token = request
        committed = false
        messageID = nil
        messageIDs = []
        acceptancePending = false
        sentInput = draft.captionInput
        sentCaption = draft.captionInput.formattedText
        sentCaptionAboveMedia = draft.captionAboveMedia
        sentMediaSpoiler = draft.mediaSpoiler
        phase = .storing
        error = nil
        startSubmissionDeadline(request: request)
        willSubmit?(target, sentCaption)
        guard token == request, phase == .storing else { return }
        let returned = provider.submit(bundle: bundle, draft: draft, target: target) { [weak self] event in
            guard let self, self.token == request else { return }
            switch event {
            case .awaitingApproval: self.receive(.awaitingApproval)
            case .committing: self.receive(.committing)
            case let .accepted(ids):
                guard self.committed, self.messageIDs.isEmpty, !ids.isEmpty else { return }
                self.messageIDs = ids.map(\.description)
                self.messageID = self.messageIDs.first
                self.acceptancePending = true
                self.deadline?.cancel()
                self.deadline = nil
                self.confirmBatchAcceptance(store: store, draft: draft, ids: ids, bound: self.bindingID)
            case let .progress(progress): self.receive(.progress(progress))
            case .queueFailed: self.receive(.queueFailed)
            case .rejected: self.receive(.rejected)
            case .uncertain: self.receive(.uncertain)
            }
        }
        if token == request, phase != .rejected, phase != .cancelled, phase != .failed { lease = returned } else { returned.stop() }
    }

    func confirmBatchAcceptance(
        store: any TelegramUploadRecoveryStore, draft: TelegramPendingUploadDraft,
        ids: [TelegramUploadQueueID], bound: UUID
    ) {
        isRecoveryBusy = true
        recoveryRetry = nil
        Task { [weak self] in
            do {
                // String equality merges canonical Unicode spellings; the ZIP
                // descriptor must preserve its exact encoded member names.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let accepted = try await store.load(chatID: draft.chatID), accepted.id == draft.id,
                    accepted.resourceSchemaVersion == draft.resourceSchemaVersion, accepted.accountID == draft.accountID,
                    accepted.chatID == draft.chatID,
                    accepted.title == draft.title, accepted.items == draft.items, accepted.isGrouped == draft.isGrouped,
                    try encoder.encode(accepted.archive) == encoder.encode(draft.archive),
                    accepted.presentation == draft.presentation, accepted.captionRules == draft.captionRules,
                    accepted.captionPolicy == draft.captionPolicy, accepted.mediaRules == draft.mediaRules,
                    accepted.captionInput == draft.captionInput, accepted.captionAboveMedia == draft.captionAboveMedia,
                    accepted.mediaSpoiler == draft.mediaSpoiler, accepted.originalDraft == draft.originalDraft,
                    accepted.replyTarget == draft.replyTarget, accepted.disposition == .acceptedBatch(messageIDs: ids)
                else {
                    throw TelegramPendingUploadPersistenceError.conflict
                }
                guard let self, self.bindingID == bound, self.preparationID == draft.id, self.messageIDs == ids.map(\.description) else {
                    return
                }
                self.isRecoveryBusy = false
                self.recoveryStatus = nil
                self.acknowledgeAccepted()
            } catch {
                guard let self, self.bindingID == bound, self.preparationID == draft.id, self.messageIDs == ids.map(\.description) else {
                    return
                }
                self.isRecoveryBusy = false
                self.phase = .uncertain
                self.recoveryStatus = "Не удалось подтвердить весь набор в очереди. Повтор отправки запрещён."
                self.recoveryRetry = { [weak self] in self?.confirmBatchAcceptance(store: store, draft: draft, ids: ids, bound: bound) }
            }
        }
    }

    func dispatch(
        provider: any TelegramUploadProvider, file: TelegramUploadFile, target: TelegramUploadTarget, frozen: TelegramComposerInput,
        above: Bool, spoiler: Bool
    ) {
        guard let preparationID else { return }
        let request = UUID()
        token = request
        sentInput = frozen
        sentCaption = frozen.formattedText
        sentCaptionAboveMedia = above
        committed = false
        sentMediaSpoiler = spoiler
        phase = .storing
        error = nil
        startSubmissionDeadline(request: request)
        willSubmit?(target, sentCaption)
        guard token == request, phase == .storing else { return }
        let returned = provider.submit(
            file: file, target: target, preparationID: preparationID, caption: sentCaption, captionAboveMedia: above, mediaSpoiler: spoiler
        ) { [weak self] event in
            guard let self, self.token == request else { return }
            self.receive(event)
        }
        if token == request, phase != .rejected, phase != .cancelled, phase != .failed { lease = returned } else { returned.stop() }
    }

    public func cancelPreparation() {
        guard canCancel else { return }
        tombstoneKnownUnsent()
        preparingRecordedVoice = false
        preparingRecordedRoundVideo = false
        token = UUID()
        preparation?.cancel()
        deadline?.cancel()
        deadline = nil
        let old = lease
        lease = nil
        old?.stop()
        releaseStage()
        phase = .cancelled
        finishPreparation()
    }

    public func clear() {
        if !committed && phase != .uncertain && !acceptancePending { tombstoneKnownUnsent() }
        resetObservation()
    }

    func resetObservation() {
        pendingCaptionEmojiInsertion = nil
        captionCustomEmojiInsertion = nil
        if appendOperationID != nil {
            preparation?.cancel()
            preparation = nil
            appendOperationID = nil
        }
        sourceURLsByItemID = [:]
        recoveryRestoreEpoch = UUID()
        videoCoverEditingID = nil
        videoCoverWriteRevision = nil
        videoCoverRevision = UUID()
        // Rebinding detaches UI observation, not the user's latest preparation.
        // The original initial-write task consumes this snapshot on completion.
        if let id = preparationID, let write = videoCoverWrites[id] {
            // The original cover write owns both its candidate and frozen caption.
            // A failed write remains explicitly retryable against its original store.
            if !write.isRunning, !cancellationStarted.contains(id) {
                detachedRecoveryRetries[id] = { [weak self, write] in self?.persistVideoCover(write) }
            }
            updateDetachedRecoveryStatus()
        } else if let id = preparationID, var write = presentationWrites[id] {
            // A caption-only detached save must not replace the pending mode/list CAS.
            if !cancellationStarted.contains(id) {
                write.input = captionInput
                write.above = captionAboveMedia
                write.spoiler = mediaSpoiler
                presentationWrites[id] = write
                if !detachedRecoveryWrites.contains(id) {
                    let frozen = write
                    presentationWrites.removeValue(forKey: id)
                    detachedRecoveryRetries[id] = { [weak self] in self?.writePresentation(frozen) }
                }
            } else if !detachedRecoveryWrites.contains(id) {
                finishPresentationWrite(id)
            }
            updateDetachedRecoveryStatus()
        } else if recoveryInitialInFlight, let id = preparationID, cancelledRecoveryContents[id] == nil {
            detachedInitialContents[id] = (captionInput, captionAboveMedia, mediaSpoiler)
        } else if phase == .ready, recoveryPrepared || usesBatchRecovery, let id = preparationID, let target, let store = recoveryStore,
            !cancellationStarted.contains(id)
        {
            persistDetachedPreparation(
                store: store, id: id, chatID: target.chatID,
                input: captionInput, above: captionAboveMedia, spoiler: mediaSpoiler)
        }
        let possiblyQueued = committed || messageID != nil || phase == .uncertain
        token = UUID()
        preparation?.cancel()
        deadline?.cancel()
        deadline = nil
        let old = lease
        lease = nil
        old?.stop()
        let cleaned = releaseStage()
        target = nil
        captionInput = .empty
        messageID = nil
        messageIDs = []
        committed = false
        usesBatchRecovery = false
        captionRules = .legacy
        captionPolicy = nil
        mediaRules = .legacy
        preparingRecordedVoice = false
        preparingRecordedRoundVideo = false
        isGrouped = false
        presentation = .media
        itemsRevision = UUID()
        captionAboveMedia = false
        mediaSpoiler = false
        captionRevision = UUID()
        phase = .idle
        acceptancePending = false
        recoveryPrepared = false
        recoveryRetry = nil
        isRecoveryBusy = false
        recoveryStatus = nil
        let notice = "Отправка могла остаться в очереди Telegram. Повторно автоматически не отправляем."
        error = !cleaned ? "Не удалось удалить временный файл." + (possiblyQueued ? " " + notice : "") : possiblyQueued ? notice : nil
        finishPreparation()
    }

    func startSubmissionDeadline(request: UUID) {
        deadline?.cancel()
        let timeout = submissionTimeout
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.token == request else { return }
            self.expireSubmission()
        }
    }

    func expireSubmission() {
        guard phase == .storing || phase == .enqueuing else { return }
        if committed {
            phase = .uncertain
            error = "Результат постановки в очередь пока неизвестен. Не отправляйте повторно."
        } else {
            token = UUID()
            let old = lease
            lease = nil
            old?.stop()
            tombstoneKnownUnsent()
            phase = .failed
            error = "Не удалось подготовить очередь отправки."
            cleanup()
            finishPreparation()
        }
        deadline?.cancel()
        deadline = nil
    }

    func receive(_ event: TelegramUploadEvent) {
        switch event {
        case .awaitingApproval:
            guard phase == .storing || phase == .enqueuing, messageID == nil, !acceptancePending else { return }
            // The provider has not entered the native enqueue transaction yet.
            // User confirmation has no network deadline and remains cancellable.
            committed = false
            phase = .storing
            deadline?.cancel()
            deadline = nil
        case .committing:
            guard phase == .storing else { return }
            committed = true
            phase = .enqueuing
            startSubmissionDeadline(request: token)
        case .accepted(let id):
            guard messageID == nil, !id.isEmpty, committed else { return }
            acceptancePending = true
            messageID = id
            messageIDs = [id]
            deadline?.cancel()
            deadline = nil
            if let store = recoveryStore, let preparationID, let target {
                persistAcceptance(
                    store: store, id: preparationID, target: target, input: sentInput,
                    localMessageID: id, bound: bindingID, above: sentCaptionAboveMedia, spoiler: sentMediaSpoiler)
            } else {
                acknowledgeAccepted()
            }
        case .progress(let value):
            guard messageID != nil, !acceptancePending else { return }
            phase = .queued(value.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil })
        case .queueFailed:
            guard messageID != nil, !acceptancePending else { return }
            phase = .queueFailed
        case .rejected:
            guard messageID == nil else { return }
            token = UUID()
            deadline?.cancel()
            deadline = nil
            let old = lease
            lease = nil
            old?.stop()
            tombstoneKnownUnsent()
            phase = .rejected
            error = "Вложение не поставлено в очередь отправки."
            cleanup()
            finishPreparation()
        case .uncertain:
            guard committed, messageID == nil else { return }
            phase = .uncertain
            error = "Результат постановки в очередь пока неизвестен. Не отправляйте повторно."
            deadline?.cancel()
            deadline = nil
        }
    }

    public func retryRecovery() {
        guard !isRecoveryBusy else { return }
        recoveryRetry?()
    }
}
