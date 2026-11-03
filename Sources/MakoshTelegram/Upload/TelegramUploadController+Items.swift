import Foundation
import MakoshCore

/// Appending, reordering, grouping and removing prepared items.
extension TelegramUploadController {
    public var isAppendingItems: Bool { appendOperationID != nil }

    public var canAppendItems: Bool {
        usesBatchRecovery && mediaRules == .reference && !containsRecordedMedia && !items.isEmpty
            && items.allSatisfy { $0.sourceFacts != nil } && phase == .ready && recoveryPrepared && !isRecoveryBusy
            && videoCoverEditingID == nil && !isVideoCoverSaving && recoveryStore?.accountID == target?.accountID
    }

    struct AppendWrite {
        let operation: UUID
        let store: any TelegramUploadRecoveryStore
        let id: UUID
        let target: TelegramUploadTarget
        let binding: UUID
        let token: UUID
        let revision: UUID
        let previousIDs: [UUID]
        let input: TelegramComposerInput
        let above: Bool
        let spoiler: Bool
        let presentation: TelegramUploadPresentation
        let grouped: Bool
        let policy: TelegramUploadCaptionPolicy?
        let sources: [URL]
    }

    func isCurrent(_ write: AppendWrite) -> Bool {
        appendOperationID == write.operation && bindingID == write.binding && token == write.token && preparationID == write.id
            && itemsRevision == write.revision && items.map(\.id) == write.previousIDs && target == write.target
            && captionInput == write.input && captionAboveMedia == write.above && mediaSpoiler == write.spoiler
            && presentation == write.presentation && isGrouped == write.grouped && captionPolicy == write.policy
            && (phase == .preparing || phase == .ready)
    }

    /// Adds to the durable preparation; never replaces its existing resources or submits it.
    @discardableResult public func append(
        sources: [TelegramUploadSelection], contextID: UUID, revision: UUID,
        photoSize: TelegramUploadPhotoSize = .standard
    ) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canAppendItems, preparation == nil,
            let target, let store = recoveryStore, provider?.accountID == target.accountID, target.hasValidReplySource,
            !sources.isEmpty,
            sources.allSatisfy({ $0.source.isFileURL && ($0.source.host == nil || $0.source.host == "" || $0.source.host == "localhost") })
        else { return false }
        var seen = Set(sourceURLsByItemID.values)
        let selected = sources.filter { seen.insert($0.source.standardizedFileURL).inserted }
        guard !selected.isEmpty else { return false }
        let write = AppendWrite(
            operation: UUID(), store: store, id: contextID, target: target, binding: bindingID, token: token,
            revision: revision, previousIDs: items.map(\.id), input: captionInput, above: captionAboveMedia,
            spoiler: mediaSpoiler, presentation: presentation, grouped: isGrouped, policy: captionPolicy,
            sources: selected.map { $0.source.standardizedFileURL })
        let stage = self.stage ?? { source, mode in try await TelegramUploadFileIO.stage(source, mode: mode, photoSize: photoSize) }
        let discard = self.discard
        appendOperationID = write.operation
        phase = .preparing
        isRecoveryBusy = true
        error = nil
        recoveryRetry = nil
        recoveryStatus = "Добавляем файлы…"
        videoPlayback.stop()
        preparation = Task { [weak self] in
            var staged: [TelegramUploadBatchItem] = []
            var capture: TelegramUploadAppendCapture?
            do {
                // Complete the entire new selection before touching the old pointer.
                try await Self.stageSelections(
                    selected, photoSize: photoSize, stage: stage, staged: &staged,
                    isCurrent: { [weak self] in self?.isCurrent(write) == true })
                guard self?.isCurrent(write) == true else { throw CancellationError() }
                try await store.save(
                    preparationID: write.id, chatID: target.chatID, captionInput: write.input,
                    captionAboveMedia: write.above, mediaSpoiler: write.spoiler, disposition: .prepared)
                try Task.checkCancellation()
                guard self?.isCurrent(write) == true,
                    let snapshot = try await store.load(chatID: target.chatID), snapshot.isValid,
                    snapshot.id == write.id, snapshot.accountID == target.accountID, snapshot.chatID == target.chatID,
                    [17, 18, 19].contains(snapshot.resourceSchemaVersion), snapshot.disposition == .prepared,
                    snapshot.items.map(\.id) == write.previousIDs, snapshot.captionInput == write.input,
                    snapshot.captionAboveMedia == write.above, snapshot.mediaSpoiler == write.spoiler,
                    snapshot.presentation == write.presentation, snapshot.isGrouped == write.grouped,
                    snapshot.captionPolicy == write.policy
                else { throw TelegramPendingUploadPersistenceError.conflict }
                capture = try await store.captureAppend(snapshot: snapshot, additions: staged, target: target)
                // The immutable candidate now owns durable bytes; retry never needs these picker stages.
                for item in staged { try item.discard(using: discard) }
                staged = []
                try Task.checkCancellation()
                guard let self, self.isCurrent(write), let capture else { throw CancellationError() }
                try await self.installAppended(capture, write: write)
            } catch {
                var failed: [TelegramUploadBatchItem] = []
                for item in staged { do { try item.discard(using: discard) } catch { failed.append(item) } }
                guard let self else { return }
                if self.appendOperationID == write.operation { self.preparation = nil }
                self.retiredItems.append(contentsOf: failed)
                guard self.isCurrent(write) else { return }
                self.isRecoveryBusy = false
                self.phase = .ready
                if let capture {
                    self.recoveryPrepared = false
                    self.recoveryStatus = "Не удалось подтвердить добавление файлов. Повторите сохранение или закройте подготовку."
                    self.recoveryRetry = { [weak self] in self?.retryAppend(capture, write: write) }
                } else {
                    self.appendOperationID = nil
                    self.recoveryStatus = nil
                    self.error = "Не удалось добавить файлы. Предыдущий набор сохранён."
                }
                if !failed.isEmpty { self.error = "Не удалось удалить временные файлы." }
            }
        }
        return true
    }

    func retryAppend(_ capture: TelegramUploadAppendCapture, write: AppendWrite) {
        guard isCurrent(write), phase == .ready, !isRecoveryBusy, preparation == nil else { return }
        phase = .preparing
        isRecoveryBusy = true
        recoveryRetry = nil
        preparation = Task { [weak self] in
            guard let self else { return }
            do { try await self.installAppended(capture, write: write) } catch {
                guard self.isCurrent(write) else { return }
                self.preparation = nil
                self.phase = .ready
                self.isRecoveryBusy = false
                self.recoveryPrepared = false
                self.recoveryStatus = "Не удалось подтвердить добавление файлов. Повторите сохранение или закройте подготовку."
                self.recoveryRetry = { [weak self] in self?.retryAppend(capture, write: write) }
            }
        }
    }

    func installAppended(_ capture: TelegramUploadAppendCapture, write: AppendWrite) async throws {
        try Task.checkCancellation()
        guard isCurrent(write) else { throw CancellationError() }
        let saved = try await write.store.installAppend(capture, target: write.target)
        try Task.checkCancellation()
        guard isCurrent(write) else { throw CancellationError() }
        guard try telegramUploadAppendBytes(saved) == capture.candidateBytes else {
            throw TelegramPendingUploadPersistenceError.conflict
        }
        let bundle = try await write.store.restoreBundle(draft: saved)
        do {
            try Task.checkCancellation()
            guard isCurrent(write) else { throw CancellationError() }
            let validate = willValidateUpload
            let valid = try await BackgroundWork.run {
                try validate?()
                return Self.matchesItems(bundle.items, draft: saved)
                    && (saved.archive == nil
                        ? bundle.archive == nil : Self.matchesArchive(bundle.archive, draft: saved))
            }
            guard !Task.isCancelled, isCurrent(write), valid else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            let old = items + retiredItems, oldArchive = recoveredArchive
            items = bundle.items
            retiredItems = []
            recoveredArchive = bundle.archive
            archiveDescriptor = saved.archive
            selectedItemID = bundle.items.last?.id
            for (item, source) in zip(bundle.items.suffix(write.sources.count), write.sources) { sourceURLsByItemID[item.id] = source }
            captionPolicy = saved.captionPolicy
            captionRules = saved.captionRules
            mediaRules = saved.mediaRules
            presentation = saved.presentation
            isGrouped = saved.isGrouped
            itemsRevision = UUID()
            captionRevision = UUID()
            videoCoverRevision = UUID()
            appendOperationID = nil
            preparation = nil
            phase = .ready
            isRecoveryBusy = false
            recoveryPrepared = true
            recoveryStatus = nil
            recoveryRetry = nil
            error = nil
            for item in old {
                do { try item.discard(using: discard) } catch {
                    retiredItems.append(item)
                    self.error = "Не удалось удалить временные файлы."
                }
            }
            if let oldArchive {
                do { try discard(oldArchive.file) } catch {
                    retiredItems.append(.init(id: oldArchive.file.id, file: oldArchive.file))
                    self.error = "Не удалось удалить временный файл."
                }
            }
        } catch {
            try? await Self.discardBundle(bundle)
            throw error
        }
    }

    nonisolated static func discardBundle(_ bundle: TelegramRecoveredUploadBundle) async throws {
        try await Task.detached(priority: .utility) { try bundle.discard() }.value
    }

    @discardableResult public func moveItem(id: UUID, to index: Int, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditItems,
            items.indices.contains(index), let oldIndex = items.firstIndex(where: { $0.id == id })
        else { return false }
        if oldIndex == index { return true }
        let oldIDs = items.map(\.id), oldGrouping = isGrouped, oldPresentation = presentation
        let item = items.remove(at: oldIndex)
        items.insert(item, at: index)
        normalizePresentationAfterItemEdit()
        itemsRevision = UUID()
        persistItems(previousIDs: oldIDs, previousGrouping: oldGrouping, previousPresentation: oldPresentation)
        return true
    }

    @discardableResult public func removeItem(id: UUID, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditItems,
            let index = items.firstIndex(where: { $0.id == id })
        else { return false }
        if items.count == 1 {
            cancelPreparation()
            return true
        }
        let oldIDs = items.map(\.id), oldGrouping = isGrouped, oldPresentation = presentation
        sourceURLsByItemID.removeValue(forKey: id)
        retiredItems.append(items.remove(at: index))
        videoPlayback.stop()
        if selectedItemID == id {
            selectedItemID = items[min(index, items.count - 1)].id
            videoCoverRevision = UUID()
        }
        normalizePresentationAfterItemEdit()
        itemsRevision = UUID()
        persistItems(previousIDs: oldIDs, previousGrouping: oldGrouping, previousPresentation: oldPresentation)
        return true
    }

    func normalizePresentationAfterItemEdit() {
        if let captionPolicy { self.captionPolicy = try? captionPolicy.reordered(items.map(\.id)) }
        if presentation == .media && !TelegramUploadBatchItem.allowsMedia(items, rules: mediaRules) {
            presentation = .file
            captionRevision = UUID()
            videoCoverRevision = UUID()
        }
        isGrouped = isGrouped && canGroupItems
    }

    @discardableResult public func updateGrouping(_ grouped: Bool, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditItems, !grouped || canGroupItems else { return false }
        if isGrouped == grouped { return true }
        let oldGrouping = isGrouped
        isGrouped = grouped
        itemsRevision = UUID()
        persistItems(previousIDs: items.map(\.id), previousGrouping: oldGrouping, previousPresentation: presentation)
        return true
    }

    @discardableResult public func selectItem(id: UUID, contextID: UUID) -> Bool {
        guard preparationID == contextID, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving,
            items.contains(where: { $0.id == id })
        else { return false }
        if selectedItemID != id {
            videoPlayback.stop()
            selectedItemID = id
            videoCoverRevision = UUID()
        }
        return true
    }

    func persistItems(previousIDs: [UUID], previousGrouping: Bool, previousPresentation: TelegramUploadPresentation) {
        guard let store = recoveryStore, let id = preparationID, let target else { return }
        writePresentation(
            .init(
                store: store, id: id, target: target, binding: bindingID, revision: itemsRevision,
                previousIDs: previousIDs, orderedIDs: items.map(\.id), previousPresentation: previousPresentation,
                previousGrouping: previousGrouping, presentation: presentation, isGrouped: isGrouped, cachedArchive: archiveDescriptor,
                captionPolicy: captionPolicy,
                input: captionInput, above: captionAboveMedia, spoiler: mediaSpoiler))
    }
}
