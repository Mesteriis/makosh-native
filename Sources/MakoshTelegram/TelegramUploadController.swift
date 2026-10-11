import Foundation
import Combine

public struct TelegramUploadTarget: Equatable, Sendable {
    public let accountID: Int64
    public let chatID: Int64
    public let title: String
    public let replySource: TelegramMessageActionSource?
    public init(accountID: Int64, chatID: Int64, title: String, replySource: TelegramMessageActionSource? = nil) {
        self.accountID = accountID; self.chatID = chatID; self.title = title
        self.replySource = replySource
    }
    var hasValidReplySource: Bool {
        guard let source = replySource else { return true }
        return source.accountID == accountID && source.chatID == chatID && source.canReply &&
            !source.fingerprint.isEmpty && (source.peerID == chatID || source.metadata.migrationChatID == chatID)
    }
}
public enum TelegramUploadPhase: Equatable, Sendable {
    case idle, preparing, ready, storing, enqueuing, queued(Double?), queueFailed
    case rejected, uncertain, cancelled, failed
}
@MainActor protocol TelegramUploadLease: AnyObject { func stop() }
@MainActor protocol TelegramUploadProvider: AnyObject {
    var accountID: Int64 { get }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText, captionAboveMedia: Bool, mediaSpoiler: Bool,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease
}
enum TelegramUploadEvent {
    case committing, accepted(String), progress(Double?), queueFailed, rejected, uncertain
}

@MainActor public final class TelegramUploadController: ObservableObject {
    public let videoPlayback = TelegramUploadVideoPlaybackController()
    public func openVideoPreview(contextID: UUID) async {
        guard preparationID == contextID, phase == .ready, !mediaSpoiler, let file, file.mode == .video, file.videoCover == nil else { return }
        await videoPlayback.load(file)
    }
    public func stopVideoPreview(contextID: UUID) {
        guard preparationID == contextID else { return }
        videoPlayback.stop()
    }
    @Published public private(set) var phase: TelegramUploadPhase = .idle
    @Published public private(set) var file: TelegramUploadFile?
    @Published public private(set) var target: TelegramUploadTarget?
    @Published public private(set) var captionInput: TelegramComposerInput = .empty
    @Published public private(set) var mediaSpoiler = false
    @discardableResult
    public func updateMediaSpoiler(_ spoiler: Bool, contextID: UUID, revision: UUID) -> Bool {
        guard token == contextID, captionRevision == revision, phase == .ready,
              file?.mode == .photo || file?.mode == .video else { return false }
        if mediaSpoiler != spoiler {
            if spoiler { videoPlayback.stop() }
            mediaSpoiler = spoiler; captionRevision = UUID(); persistCaption()
        }
        return true
    }
    @Published public private(set) var captionAboveMedia = false
    @Published public private(set) var captionRevision = UUID()
    @discardableResult
    public func updateCaptionPlacement(_ above: Bool, contextID: UUID, revision: UUID) -> Bool {
        guard token == contextID, captionRevision == revision, phase == .ready,
              file?.mode == .photo || file?.mode == .video else { return false }
        if captionAboveMedia != above {
            captionAboveMedia = above; captionRevision = UUID(); persistCaption()
        }
        return true
    }
    public var caption: String {
        get { captionInput.formattedText.text }
        set {
            guard !newValue.utf8.elementsEqual(caption.utf8) else { return }
            guard let input = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: newValue)) else {
                error = "Не удалось сохранить подпись."; return
            }
            captionInput = input; captionRevision = UUID()
            persistCaption()
        }
    }
    @Published public private(set) var messageID: String?
    @Published public private(set) var error: String?
    @Published public private(set) var recoveryStatus: String?
    @Published public private(set) var isRecoveryBusy = false
    public var canRetryRecovery: Bool { recoveryRetry != nil && !isRecoveryBusy }
    @Published public private(set) var cancellationStatus: String?
    @Published public private(set) var isCancellationBusy = false
    public var canRetryCancellation: Bool { cancellationRetry != nil && !isCancellationBusy }
    public func retryCancellation() { guard !isCancellationBusy else { return }; cancellationRetry?() }
    private var cancellationRetry: (() -> Void)?
    private var cancellationPresentationID = UUID()
    private var cancellationStarted: Set<UUID> = []
    private var recoveryRetry: (() -> Void)?
    private var recoveryStore: (any TelegramUploadRecoveryStore)?
    private var requiresRecovery = false
    private var recoveryPrepared = false
    private var recoveryInitialInFlight = false
    private var bindingID = UUID()
    private(set) var recoveryRestoreEpoch = UUID()
    private var acceptancePending = false
    private var cancelledRecoveryContents: [UUID: (input: TelegramComposerInput, above: Bool, spoiler: Bool)] = [:]
    private var sentCaptionAboveMedia = false
    private var sentMediaSpoiler = false
    @Published public private(set) var detachedRecoveryStatus: String?
    public var canRetryDetachedRecovery: Bool { !detachedRecoveryRetries.isEmpty }
    public func retryDetachedRecovery() { for retry in Array(detachedRecoveryRetries.values) { retry() } }
    private var detachedInitialContents: [UUID: (input: TelegramComposerInput, above: Bool, spoiler: Bool)] = [:]
    private var detachedRecoveryWrites: Set<UUID> = []
    private var detachedRecoveryRetries: [UUID: () -> Void] = [:]
    private var sentInput: TelegramComposerInput = .empty
    var originalDraftForRecovery: ((TelegramUploadTarget, UUID) -> TelegramComposerDraft?)?
    var didRestore: ((TelegramUploadTarget, TelegramComposerDraft?, UUID) -> Void)?
    private var provider: (any TelegramUploadProvider)?
    private var lease: (any TelegramUploadLease)?
    private var preparation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var token = UUID()
    private var preparationID: UUID?
    private var committed = false
    private var sentCaption = TelegramComposerInput.empty.formattedText
    var didQueue: ((TelegramUploadTarget, TelegramFormattedText) -> Void)?
    var willSubmit: ((TelegramUploadTarget, TelegramFormattedText) -> Void)?
    var didPrepare: ((TelegramUploadTarget, TelegramComposerInput, UUID) -> Void)?
    var didFinishPreparation: ((UUID) -> Void)?
    // Per-instance deterministic staging seam, with identical ownership semantics.
    var stage: (URL, TelegramUploadMode) async throws -> TelegramUploadFile = TelegramUploadFileIO.stage
    var discard: (TelegramUploadFile) throws -> Void = TelegramUploadFileIO.discard

    public init() {}
    public var canSend: Bool { phase == .ready && !isRecoveryBusy && ((!requiresRecovery && recoveryStore == nil) || recoveryPrepared) && provider?.accountID == target?.accountID && telegramFormattedCaptionCanSend(captionInput.formattedText) }
    public var canCancel: Bool { phase == .preparing || phase == .ready || phase == .storing }
    public var captionContextID: UUID { token }
    public var preparationContextID: UUID? { preparationID }
    public var showsPreparationPreview: Bool {
        guard preparationID != nil else { return false }
        switch phase {
        case .preparing, .ready, .storing, .enqueuing, .uncertain: return true
        default: return false
        }
    }

    public func send(contextID: UUID) {
        guard preparationID == contextID else { return }
        send()
    }

    public func sendAsSpoiler(contextID: UUID, revision: UUID) {
        guard preparationID == contextID, captionRevision == revision,
              file?.mode == .photo || file?.mode == .video, canSend else { return }
        send(spoilerOverride: true)
    }

    public func dismissPreparation(contextID: UUID) {
        guard preparationID == contextID else { return }
        if canCancel { cancelPreparation(); clear() }
        else if phase == .uncertain { clear() }
    }

    @discardableResult
    public func updateCaptionInput(_ input: TelegramComposerInput, contextID: UUID) -> Bool {
        guard token == contextID, phase == .ready else { return false }
        if captionInput != input { captionInput = input; captionRevision = UUID() }
        error = nil; persistCaption(); return true
    }

    func bind(provider: (any TelegramUploadProvider)?, recoveryStore: (any TelegramUploadRecoveryStore)? = nil, requiresRecovery: Bool = false) {
        // Rebinding detaches observation, preserving durable recovery state.
        resetObservation()
        bindingID = UUID()
        resetCancellationPresentation()
        self.provider = provider; self.recoveryStore = recoveryStore; self.requiresRecovery = requiresRecovery
    }

    public func prepare(source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, caption: String) {
        guard let input = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: caption)) else {
            error = "Не удалось подготовить подпись."; return
        }
        prepare(source: source, mode: mode, target: target, captionInput: input)
    }

    public func prepare(source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, captionInput: TelegramComposerInput) {
        guard preparation == nil, phase == .idle || phase == .cancelled || phase == .failed || phase == .rejected,
              provider?.accountID == target.accountID, target.hasValidReplySource else { return }
        clear()
        resetCancellationPresentation()
        guard file == nil else { phase = .failed; return }
        self.target = target; self.captionInput = captionInput; phase = .preparing
        let request = token, stage = self.stage, discard = self.discard
        let bound = bindingID, store = recoveryStore
        preparationID = request
        didPrepare?(target, captionInput, request)
        guard token == request, phase == .preparing else { return }
        let original = originalDraftForRecovery?(target, request)
        preparation = Task { [weak self] in
            do {
                let result = try await stage(source, mode)
                guard let self else { try? discard(result); return }
                guard self.token == request, !Task.isCancelled else {
                    do { try discard(result) } catch {
                        if self.bindingID == bound { self.error = "Не удалось удалить временный файл." }
                    }
                    self.preparation = nil
                    return
                }
                self.preparation = nil; self.file = result; self.phase = .ready
                if self.requiresRecovery || store != nil {
                    self.persistInitial(file: result, target: target, input: captionInput, original: original,
                        id: request, bound: bound, store: store, above: false, spoiler: false)
                }
            } catch {
                guard let self else { return }
                self.preparation = nil
                guard self.token == request else { return }
                self.phase = Task.isCancelled ? .cancelled : .failed
                if !Task.isCancelled { self.error = "Не удалось подготовить вложение." }
                self.finishPreparation()
            }
        }
    }

    public func send() { send(spoilerOverride: nil) }

    private func send(spoilerOverride: Bool?) {
        guard telegramFormattedCaptionCanSend(captionInput.formattedText) else {
            error = "Подпись или её форматирование не поддерживаются. Максимум — 1024 знака UTF16."; return
        }
        guard canSend, let provider, let file, let target else { return }
        videoPlayback.stop()
        let frozen = captionInput, frozenAbove = captionAboveMedia, frozenSpoiler = spoilerOverride ?? mediaSpoiler
        if let store = recoveryStore, let id = preparationID {
            let bound = bindingID
            isRecoveryBusy = true; recoveryRetry = nil
            phase = .storing
            Task { [weak self] in
                guard self?.bindingID == bound, self?.preparationID == id, self?.phase == .storing else { return }
                do {
                    try await store.save(preparationID: id, chatID: target.chatID, captionInput: frozen, captionAboveMedia: frozenAbove, mediaSpoiler: frozenSpoiler, disposition: .submissionStarted)
                    guard let self, self.bindingID == bound, self.preparationID == id, self.phase == .storing else { return }
                    self.isRecoveryBusy = false
                    self.dispatch(provider: provider, file: file, target: target, frozen: frozen, above: frozenAbove, spoiler: frozenSpoiler)
                } catch {
                    guard let self, self.bindingID == bound, self.preparationID == id, self.phase == .storing else { return }
                    // A failed write acknowledgement may have committed the marker.
                    // Retry only persistence, never submit through this failure path.
                    self.isRecoveryBusy = false; self.phase = .uncertain
                    self.recoveryStatus = "Не удалось подтвердить сохранение начала отправки. Автоматического повтора нет."
                }
            }
        } else if !requiresRecovery { dispatch(provider: provider, file: file, target: target, frozen: frozen, above: frozenAbove, spoiler: frozenSpoiler) }
    }

    private func dispatch(provider: any TelegramUploadProvider, file: TelegramUploadFile, target: TelegramUploadTarget, frozen: TelegramComposerInput, above: Bool, spoiler: Bool) {
        guard let preparationID else { return }
        let request = UUID(); token = request; sentInput = frozen; sentCaption = frozen.formattedText; sentCaptionAboveMedia = above; committed = false
        sentMediaSpoiler = spoiler
        phase = .storing; error = nil
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.token == request else { return }
            self.expireSubmission()
        }
        willSubmit?(target, sentCaption)
        guard token == request, phase == .storing else { return }
        let returned = provider.submit(file: file, target: target, preparationID: preparationID, caption: sentCaption, captionAboveMedia: above, mediaSpoiler: spoiler) { [weak self] event in
            guard let self, self.token == request else { return }
            self.receive(event)
        }
        if token == request, phase != .rejected, phase != .cancelled, phase != .failed { lease = returned }
        else { returned.stop() }
    }

    public func cancelPreparation() {
        guard canCancel else { return }
        tombstoneKnownUnsent()
        token = UUID(); preparation?.cancel(); deadline?.cancel(); deadline = nil
        let old = lease; lease = nil; old?.stop()
        releaseStage(); phase = .cancelled
        finishPreparation()
    }

    public func clear() {
        if !committed && phase != .uncertain && !acceptancePending { tombstoneKnownUnsent() }
        resetObservation()
    }

    private func resetObservation() {
        recoveryRestoreEpoch = UUID()
        // Rebinding detaches UI observation, not the user's latest preparation.
        // The original initial-write task consumes this snapshot on completion.
        if recoveryInitialInFlight, let id = preparationID, cancelledRecoveryContents[id] == nil {
            detachedInitialContents[id] = (captionInput, captionAboveMedia, mediaSpoiler)
        } else if phase == .ready, recoveryPrepared, let id = preparationID, let target, let store = recoveryStore,
                  !cancellationStarted.contains(id) {
            persistDetachedPreparation(store: store, id: id, chatID: target.chatID,
                input: captionInput, above: captionAboveMedia, spoiler: mediaSpoiler)
        }
        let possiblyQueued = committed || messageID != nil || phase == .uncertain
        token = UUID(); preparation?.cancel(); deadline?.cancel(); deadline = nil
        let old = lease; lease = nil; old?.stop()
        let cleaned = releaseStage(); target = nil; captionInput = .empty; messageID = nil; committed = false
        captionAboveMedia = false; mediaSpoiler = false; captionRevision = UUID()
        phase = .idle; acceptancePending = false; recoveryPrepared = false
        recoveryRetry = nil; isRecoveryBusy = false; recoveryStatus = nil
        let notice = "Отправка могла остаться в очереди Telegram. Повторно автоматически не отправляем."
        error = !cleaned ? "Не удалось удалить временный файл." + (possiblyQueued ? " " + notice : "") : possiblyQueued ? notice : nil
        finishPreparation()
    }

    func expireSubmission() {
        guard phase == .storing || phase == .enqueuing else { return }
        if committed {
            phase = .uncertain; error = "Результат постановки в очередь пока неизвестен. Не отправляйте повторно."
        } else {
            token = UUID(); let old = lease; lease = nil; old?.stop()
            tombstoneKnownUnsent()
            phase = .failed; error = "Не удалось подготовить очередь отправки."; cleanup()
            finishPreparation()
        }
        deadline?.cancel(); deadline = nil
    }

    private func receive(_ event: TelegramUploadEvent) {
        switch event {
        case .committing:
            guard phase == .storing else { return }
            committed = true; phase = .enqueuing
        case .accepted(let id):
            guard messageID == nil, !id.isEmpty, committed else { return }
            acceptancePending = true; messageID = id
            deadline?.cancel(); deadline = nil
            if let store = recoveryStore, let preparationID, let target {
                persistAcceptance(store: store, id: preparationID, target: target, input: sentInput,
                    localMessageID: id, bound: bindingID, above: sentCaptionAboveMedia, spoiler: sentMediaSpoiler)
            } else { acknowledgeAccepted() }
        case .progress(let value):
            guard messageID != nil, !acceptancePending else { return }
            phase = .queued(value.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil })
        case .queueFailed:
            guard messageID != nil, !acceptancePending else { return }
            phase = .queueFailed
        case .rejected:
            guard messageID == nil else { return }
            token = UUID(); deadline?.cancel(); deadline = nil
            let old = lease; lease = nil; old?.stop()
            tombstoneKnownUnsent()
            phase = .rejected; error = "Вложение не поставлено в очередь отправки."; cleanup()
            finishPreparation()
        case .uncertain:
            guard committed, messageID == nil else { return }
            phase = .uncertain; error = "Результат постановки в очередь пока неизвестен. Не отправляйте повторно."
            deadline?.cancel(); deadline = nil
        }
    }
    public func retryRecovery() { guard !isRecoveryBusy else { return }; recoveryRetry?() }

    private func persistInitial(file: TelegramUploadFile, target: TelegramUploadTarget, input: TelegramComposerInput,
                                original: TelegramComposerDraft?, id: UUID, bound: UUID, store: (any TelegramUploadRecoveryStore)?, above: Bool, spoiler: Bool) {
        guard let store, store.accountID == target.accountID else {
            recoveryPrepared = false; recoveryStatus = "Настройте хранилище вложений для сохранения перед отправкой."
            recoveryRetry = nil
            return
        }
        isRecoveryBusy = true; recoveryInitialInFlight = true; recoveryRetry = nil
        let discard = self.discard, cancellationPresentation = cancellationPresentationID
        Task { [weak self] in
            do {
                try await store.prepare(preparationID: id, file: file, target: target, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, originalDraft: original)
                if let cancelled = self?.cancelledRecoveryContents.removeValue(forKey: id) {
                    self?.persistCancellation(store: store, id: id, chatID: target.chatID, input: cancelled.input, bound: bound, above: cancelled.above, spoiler: cancelled.spoiler, presentation: cancellationPresentation)
                }
                self?.persistDetachedInitialIfNeeded(store: store, id: id, chatID: target.chatID)
                guard let self, self.bindingID == bound, self.preparationID == id else { try? discard(file); return }
                self.recoveryInitialInFlight = false; self.isRecoveryBusy = false; self.recoveryPrepared = true; self.recoveryStatus = nil
                if self.captionInput != input || self.captionAboveMedia != above || self.mediaSpoiler != spoiler { self.persistCaption() }
            } catch {
                if let cancelled = self?.cancelledRecoveryContents.removeValue(forKey: id) {
                    self?.persistCancellation(store: store, id: id, chatID: target.chatID, input: cancelled.input, bound: bound, above: cancelled.above, spoiler: cancelled.spoiler, presentation: cancellationPresentation)
                }
                self?.persistDetachedInitialIfNeeded(store: store, id: id, chatID: target.chatID)
                guard let self, self.bindingID == bound, self.preparationID == id else { try? discard(file); return }
                self.recoveryInitialInFlight = false; self.isRecoveryBusy = false; self.recoveryPrepared = false
                self.recoveryStatus = "Не удалось сохранить вложение. Отправка заблокирована."
                self.recoveryRetry = { [weak self] in self?.persistInitial(file: file, target: target, input: input, original: original, id: id, bound: bound, store: store, above: above, spoiler: spoiler) }
            }
        }
    }
    private func persistCaption() {
        guard let store = recoveryStore, recoveryPrepared, let id = preparationID, let target, phase == .ready else { return }
        let bound = bindingID, input = captionInput, above = captionAboveMedia, spoiler = mediaSpoiler
        Task { [weak self] in
            guard self?.bindingID == bound, self?.preparationID == id, self?.phase == .ready, self?.captionInput == input, self?.captionAboveMedia == above, self?.mediaSpoiler == spoiler else { return }
            do {
                try await store.save(preparationID: id, chatID: target.chatID, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, disposition: .prepared)
                guard let self, self.bindingID == bound, self.preparationID == id, self.captionInput == input, self.captionAboveMedia == above, self.mediaSpoiler == spoiler, self.phase == .ready else { return }
                self.recoveryStatus = nil; self.recoveryRetry = nil
            } catch {
                guard let self, self.bindingID == bound, self.preparationID == id, self.captionInput == input, self.captionAboveMedia == above, self.mediaSpoiler == spoiler, self.phase == .ready else { return }
                self.recoveryStatus = "Не удалось сохранить подпись. Повторите сохранение перед отправкой."
                self.recoveryRetry = { [weak self] in self?.persistCaption() }
            }
        }
    }
    private func persistDetachedInitialIfNeeded(store: any TelegramUploadRecoveryStore, id: UUID, chatID: Int64) {
        guard let content = detachedInitialContents.removeValue(forKey: id) else { return }
        persistDetachedPreparation(store: store, id: id, chatID: chatID, input: content.input, above: content.above, spoiler: content.spoiler)
    }
    private func persistDetachedPreparation(store: any TelegramUploadRecoveryStore, id: UUID, chatID: Int64,
                                            input: TelegramComposerInput, above: Bool, spoiler: Bool) {
        guard detachedRecoveryWrites.insert(id).inserted else { return }
        recoveryRestoreEpoch = UUID()
        detachedRecoveryRetries.removeValue(forKey: id); updateDetachedRecoveryStatus()
        Task { [weak self] in
            do {
                try await store.save(preparationID: id, chatID: chatID, captionInput: input,
                    captionAboveMedia: above, mediaSpoiler: spoiler, disposition: .prepared)
            } catch {
                self?.detachedRecoveryRetries[id] = { [weak self] in
                    self?.persistDetachedPreparation(store: store, id: id, chatID: chatID, input: input, above: above, spoiler: spoiler)
                }
            }
            self?.recoveryRestoreEpoch = UUID()
            self?.detachedRecoveryWrites.remove(id); self?.updateDetachedRecoveryStatus()
        }
    }
    private func updateDetachedRecoveryStatus() {
        detachedRecoveryStatus = !detachedRecoveryRetries.isEmpty
            ? "Не удалось сохранить параметры предыдущего вложения. Повторите сохранение."
            : !detachedRecoveryWrites.isEmpty ? "Сохраняем параметры предыдущего вложения…" : nil
    }
    private func resetCancellationPresentation() {
        cancellationPresentationID = UUID()
        cancellationStatus = nil; cancellationRetry = nil; isCancellationBusy = false
    }
    private func tombstoneKnownUnsent() {
        guard let store = recoveryStore, let id = preparationID, let target else { return }
        // The initial write may commit even when its acknowledgement fails. Wait
        // for its completion before publishing the cancellation marker.
        if recoveryInitialInFlight {
            cancelledRecoveryContents[id] = (captionInput, captionAboveMedia, mediaSpoiler)
            return
        }
        persistCancellation(store: store, id: id, chatID: target.chatID, input: captionInput, bound: bindingID, above: captionAboveMedia, spoiler: mediaSpoiler)
    }
    private func persistCancellation(store: any TelegramUploadRecoveryStore, id: UUID,
                                     chatID: Int64, input: TelegramComposerInput, bound: UUID, above: Bool, spoiler: Bool, presentation: UUID? = nil) {
        guard cancellationStarted.insert(id).inserted else { return }
        let presentation = presentation ?? cancellationPresentationID
        writeCancellation(store: store, id: id, chatID: chatID, input: input, bound: bound, above: above, spoiler: spoiler, presentation: presentation)
    }
    private func writeCancellation(store: any TelegramUploadRecoveryStore, id: UUID,
                                   chatID: Int64, input: TelegramComposerInput, bound: UUID, above: Bool, spoiler: Bool, presentation: UUID) {
        let current = bindingID == bound && cancellationPresentationID == presentation
        if current { isCancellationBusy = true; cancellationRetry = nil }
        Task { [weak self] in
            do {
                try await store.save(preparationID: id, chatID: chatID, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, disposition: .cancelled)
                guard let self, self.bindingID == bound, self.cancellationPresentationID == presentation else { return }
                self.isCancellationBusy = false; self.cancellationStatus = nil; self.cancellationRetry = nil
            } catch {
                guard let self, self.bindingID == bound, self.cancellationPresentationID == presentation else { return }
                self.isCancellationBusy = false
                self.cancellationStatus = "Не удалось подтвердить отмену сохранённого вложения. Повторите сохранение отмены."
                self.cancellationRetry = { [weak self] in
                    self?.writeCancellation(store: store, id: id, chatID: chatID, input: input, bound: bound, above: above, spoiler: spoiler, presentation: presentation)
                }
            }
        }
    }
    private func persistAcceptance(store: any TelegramUploadRecoveryStore, id: UUID, target: TelegramUploadTarget,
                                   input: TelegramComposerInput, localMessageID: String, bound: UUID, above: Bool, spoiler: Bool) {
        isRecoveryBusy = true; recoveryRetry = nil
        Task { [weak self] in
            do {
                try await store.save(preparationID: id, chatID: target.chatID, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, disposition: .accepted(localMessageID: localMessageID))
                guard let self, self.bindingID == bound, self.preparationID == id, self.messageID == localMessageID else { return }
                self.isRecoveryBusy = false; self.recoveryStatus = nil; self.acknowledgeAccepted()
            } catch {
                guard let self, self.bindingID == bound, self.preparationID == id, self.messageID == localMessageID else { return }
                self.isRecoveryBusy = false; self.phase = .uncertain
                self.recoveryStatus = "Очередь приняла вложение, но сохранить подтверждение не удалось. Повтор отправки запрещён."
                self.recoveryRetry = { [weak self] in self?.persistAcceptance(store: store, id: id, target: target, input: input, localMessageID: localMessageID, bound: bound, above: above, spoiler: spoiler) }
            }
        }
    }
    private func acknowledgeAccepted() {
        guard acceptancePending else { return }
        acceptancePending = false; phase = .queued(nil); error = nil; cleanup()
        let id = preparationID
        if let target { didQueue?(target, sentCaption) }
        if preparationID == id { finishPreparation() }
    }
    @discardableResult private func releaseStage() -> Bool {
        videoPlayback.stop()
        if recoveryInitialInFlight { file = nil; recoveryInitialInFlight = false; return true }
        return cleanup()
    }
    @discardableResult
    func restore(draft: TelegramPendingUploadDraft, file: TelegramUploadFile, target: TelegramUploadTarget, restorationEpoch: UUID) -> Bool {
        // A load/file export may finish after a detached write has cleared its
        // pending marker. Only a snapshot begun in the current epoch can apply.
        guard restorationEpoch == recoveryRestoreEpoch, phase == .idle, draft.isValid, provider?.accountID == draft.accountID,
              detachedInitialContents[draft.id] == nil, !detachedRecoveryWrites.contains(draft.id), detachedRecoveryRetries[draft.id] == nil,
              recoveryStore?.accountID == draft.accountID, target.accountID == draft.accountID,
              target.chatID == draft.chatID, target.hasValidReplySource,
              file.name == draft.file.attachment.name, file.size == draft.file.plaintextByteCount,
              file.mode.rawValue == draft.file.attachment.kind, file.video == draft.video,
              telegramPendingUploadCoverMatches(draft.videoCover, file.videoCover) else { return false }
        guard (try? TelegramUploadFileIO.validateOwnedStage(file)) != nil else { return false }
        if let cover = file.videoCover, (try? TelegramUploadVideoCoverIO.validatedBytes(cover)) == nil { return false }
        switch draft.disposition {
        case .prepared:
            guard draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else { return false }
        case .submissionStarted: break // Missing reply cannot authorize any new submit.
        case .accepted, .cancelled: return false
        }
        token = UUID(); preparationID = draft.id; self.file = file; self.target = target; captionInput = draft.captionInput
        captionAboveMedia = draft.captionAboveMedia; captionRevision = UUID(); sentCaptionAboveMedia = draft.captionAboveMedia
        mediaSpoiler = draft.mediaSpoiler; sentMediaSpoiler = draft.mediaSpoiler
        recoveryPrepared = true; committed = false; sentCaption = draft.captionInput.formattedText
        if case .submissionStarted = draft.disposition { phase = .uncertain; committed = true }
        else { phase = .ready }
        didRestore?(target, draft.originalDraft, draft.id)
        return true
    }
    private func finishPreparation() {
        guard let id = preparationID else { return }
        preparationID = nil
        didFinishPreparation?(id)
    }
    @discardableResult private func cleanup() -> Bool {
        videoPlayback.stop()
        guard let file else { return true }
        do { try discard(file); self.file = nil; return true }
        catch { self.error = "Не удалось удалить временный файл."; return false }
    }
    isolated deinit { videoPlayback.stop(); preparation?.cancel(); deadline?.cancel(); lease?.stop(); if let file { try? discard(file) } }
}
