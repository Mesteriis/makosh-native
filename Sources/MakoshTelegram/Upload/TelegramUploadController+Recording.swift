import Foundation

/// Preparing recorded voice and round-video messages.
extension TelegramUploadController {
    @discardableResult
    func prepareRecordedRoundVideo(bytes: Data, target: TelegramUploadTarget, isOneTime: Bool = false) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 128 * 1024 * 1024,
            preparation == nil, phase == .idle || phase == .cancelled || phase == .failed || phase == .rejected,
            provider is any TelegramUploadBatchProvider, provider?.accountID == target.accountID,
            target.hasValidReplySource
        else { return false }
        clear()
        resetCancellationPresentation()
        guard items.isEmpty, recoveredArchive == nil else {
            phase = .failed
            return false
        }
        usesBatchRecovery = true
        preparingRecordedRoundVideo = true
        presentation = .media
        self.target = target
        captionInput = .empty
        phase = .preparing
        let request = token, bound = bindingID, discard = self.discard, store = recoveryStore
        preparationID = request
        didPrepare?(target, .empty, request)
        guard token == request, phase == .preparing else { return false }
        let original = originalDraftForRecovery?(target, request)
        preparation = Task { [weak self] in
            do {
                let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes, isOneTime: isOneTime)
                guard let self else {
                    try? discard(file)
                    return
                }
                guard self.token == request, !Task.isCancelled else {
                    do { try discard(file) } catch { if self.bindingID == bound { self.error = "Не удалось удалить временный файл." } }
                    self.preparation = nil
                    return
                }
                let staged = [TelegramUploadBatchItem(id: file.id, file: file)]
                self.preparation = nil
                self.items = staged
                self.selectedItemID = file.id
                self.preparingRecordedRoundVideo = false
                self.itemsRevision = UUID()
                self.phase = .ready
                self.persistInitial(
                    file: file, target: target, input: .empty, original: original,
                    id: request, bound: bound, store: store, above: false, spoiler: false, batchItems: staged)
            } catch {
                guard let self else { return }
                self.preparation = nil
                guard self.token == request else { return }
                self.preparingRecordedRoundVideo = false
                self.phase = Task.isCancelled ? .cancelled : .failed
                if !Task.isCancelled { self.error = "Не удалось подготовить видеосообщение." }
                self.finishPreparation()
            }
        }
        return true
    }

    public var isRecordedRoundVideo: Bool { containsRecordedRoundVideo }

    public var isOneTimeRoundVideo: Bool { file?.metadata?.roundVideo?.isOneTime == true }

    /// Explicit recorded PCM bypasses the file picker and its classifier. The
    /// reference measures >0.5s using complete960-sample packets. Codec/recovery
    /// retain exact partial PCM and their historical bounds independently.
    @discardableResult
    func prepareRecordedVoice(samples: [Int16], target: TelegramUploadTarget, isOneTime: Bool = false) -> Bool {
        guard samples.count / 960 > 25, samples.count <= TelegramRecordedVoiceCodec.maximumSamples,
            preparation == nil, phase == .idle || phase == .cancelled || phase == .failed || phase == .rejected,
            provider is any TelegramUploadBatchProvider, provider?.accountID == target.accountID,
            target.hasValidReplySource
        else { return false }
        clear()
        resetCancellationPresentation()
        guard items.isEmpty, recoveredArchive == nil else {
            phase = .failed
            return false
        }
        usesBatchRecovery = true
        preparingRecordedVoice = true
        presentation = .file
        self.target = target
        captionInput = .empty
        phase = .preparing
        let request = token, bound = bindingID, discard = self.discard, store = recoveryStore
        preparationID = request
        didPrepare?(target, .empty, request)
        guard token == request, phase == .preparing else { return false }
        let original = originalDraftForRecovery?(target, request)
        preparation = Task { [weak self] in
            do {
                let file = try await TelegramRecordedVoiceIO.prepare(samples: samples, isOneTime: isOneTime)
                guard let self else {
                    try? discard(file)
                    return
                }
                guard self.token == request, !Task.isCancelled else {
                    do { try discard(file) } catch { if self.bindingID == bound { self.error = "Не удалось удалить временный файл." } }
                    self.preparation = nil
                    return
                }
                let staged = [TelegramUploadBatchItem(id: file.id, file: file)]
                self.preparation = nil
                self.items = staged
                self.selectedItemID = file.id
                self.preparingRecordedVoice = false
                self.itemsRevision = UUID()
                self.phase = .ready
                // Voice always needs a complete typed batch receipt. A missing
                // store blocks admission, including in local-only chat policy.
                self.persistInitial(
                    file: file, target: target, input: .empty, original: original,
                    id: request, bound: bound, store: store, above: false, spoiler: false, batchItems: staged)
            } catch {
                guard let self else { return }
                self.preparation = nil
                guard self.token == request else { return }
                self.preparingRecordedVoice = false
                self.phase = Task.isCancelled ? .cancelled : .failed
                if !Task.isCancelled { self.error = "Не удалось подготовить голосовое сообщение." }
                self.finishPreparation()
            }
        }
        return true
    }
}
