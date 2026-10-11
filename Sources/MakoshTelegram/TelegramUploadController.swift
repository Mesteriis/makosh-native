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
    @Published public private(set) var items: [TelegramUploadBatchItem] = []
    @Published public private(set) var itemsRevision = UUID()
    @Published public private(set) var selectedItemID: UUID?
    @Published public private(set) var isGrouped = false
    @Published public private(set) var messageIDs: [String] = []
    private var usesBatchRecovery = false
    private var retiredItems: [TelegramUploadBatchItem] = []
    public var canEditItems: Bool {
        usesBatchRecovery && phase == .ready && recoveryPrepared && !isRecoveryBusy &&
            videoCoverEditingID == nil && !isVideoCoverSaving
    }
    public var isVisualMedia: Bool { !items.isEmpty && items.allSatisfy { $0.file.mode != .file } }
    public func prepare(sources: [TelegramUploadSelection], isGrouped: Bool, target: TelegramUploadTarget, captionInput: TelegramComposerInput) {
        guard preparation == nil, phase == .idle || phase == .cancelled || phase == .failed || phase == .rejected,
              provider is any TelegramUploadBatchProvider, provider?.accountID == target.accountID, target.hasValidReplySource else { return }
        var seen: Set<URL> = []
        let selected = sources.filter { seen.insert($0.source).inserted }
        guard !selected.isEmpty, selected.allSatisfy({ $0.mode == .file }) || selected.allSatisfy({ $0.mode != .file }) else { return }
        clear(); resetCancellationPresentation()
        guard items.isEmpty else { phase = .failed; return }
        usesBatchRecovery = true; self.isGrouped = isGrouped
        self.target = target; self.captionInput = captionInput; phase = .preparing
        let request = token, bound = bindingID, stage = self.stage, discard = self.discard, store = recoveryStore
        preparationID = request; didPrepare?(target, captionInput, request)
        guard token == request, phase == .preparing else { return }
        let original = originalDraftForRecovery?(target, request)
        preparation = Task { [weak self] in
            var staged: [TelegramUploadBatchItem] = []
            do {
                for source in selected {
                    try Task.checkCancellation()
                    let file = try await stage(source.source, source.mode)
                    staged.append(.init(id: file.id, file: file))
                    try Task.checkCancellation()
                    guard self?.token == request else { throw CancellationError() }
                }
                guard let self, self.token == request else { throw CancellationError() }
                self.preparation = nil; self.items = staged; self.selectedItemID = staged[0].id
                self.itemsRevision = UUID(); self.phase = .ready
                self.persistInitial(file: staged[0].file, target: target, input: captionInput, original: original,
                    id: request, bound: bound, store: store, above: false, spoiler: false, batchItems: staged, grouped: isGrouped)
            } catch {
                var cleanupFailed = false
                for item in staged { do { try discard(item.file) } catch { cleanupFailed = true } }
                guard let self else { return }
                self.preparation = nil
                guard self.token == request else {
                    if cleanupFailed, self.bindingID == bound { self.error = "Не удалось удалить временные файлы." }
                    return
                }
                self.phase = Task.isCancelled || error is CancellationError ? .cancelled : .failed
                if cleanupFailed { self.error = "Не удалось удалить временные файлы." }
                else if self.phase == .failed { self.error = "Не удалось подготовить набор вложений." }
                self.finishPreparation()
            }
        }
    }
    @discardableResult public func moveItem(id: UUID, to index: Int, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditItems,
              items.indices.contains(index), let oldIndex = items.firstIndex(where: { $0.id == id }) else { return false }
        if oldIndex == index { return true }
        let oldIDs = items.map(\.id), oldGrouping = isGrouped
        let item = items.remove(at: oldIndex); items.insert(item, at: index)
        itemsRevision = UUID(); persistItems(previousIDs: oldIDs, previousGrouping: oldGrouping)
        return true
    }
    @discardableResult public func removeItem(id: UUID, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditItems,
              let index = items.firstIndex(where: { $0.id == id }) else { return false }
        if items.count == 1 { cancelPreparation(); return true }
        let oldIDs = items.map(\.id), oldGrouping = isGrouped
        retiredItems.append(items.remove(at: index)); videoPlayback.stop()
        if selectedItemID == id { selectedItemID = items[min(index, items.count - 1)].id; videoCoverRevision = UUID() }
        itemsRevision = UUID(); persistItems(previousIDs: oldIDs, previousGrouping: oldGrouping)
        return true
    }
    @discardableResult public func updateGrouping(_ grouped: Bool, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditItems else { return false }
        if isGrouped == grouped { return true }
        let oldGrouping = isGrouped; isGrouped = grouped; itemsRevision = UUID()
        persistItems(previousIDs: items.map(\.id), previousGrouping: oldGrouping)
        return true
    }
    @discardableResult public func selectItem(id: UUID, contextID: UUID) -> Bool {
        guard preparationID == contextID, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving,
              items.contains(where: { $0.id == id }) else { return false }
        if selectedItemID != id { videoPlayback.stop(); selectedItemID = id; videoCoverRevision = UUID() }
        return true
    }
    private func persistItems(previousIDs: [UUID], previousGrouping: Bool) {
        guard let store = recoveryStore, let id = preparationID, let target else { return }
        let bound = bindingID, revision = itemsRevision, orderedIDs = items.map(\.id), grouped = isGrouped
        isRecoveryBusy = true; recoveryPrepared = false; recoveryRetry = nil
        recoveryStatus = "Сохраняем набор вложений…"
        Task { [weak self] in
            do {
                try await store.updateItems(preparationID: id, previousIDs: previousIDs, previousGrouping: previousGrouping,
                    orderedIDs: orderedIDs, isGrouped: grouped, target: target)
                guard let self, self.bindingID == bound, self.preparationID == id, self.itemsRevision == revision, self.phase == .ready else { return }
                self.isRecoveryBusy = false; self.recoveryPrepared = true; self.recoveryStatus = nil
                var remaining: [TelegramUploadBatchItem] = []
                for item in self.retiredItems {
                    do { try self.discard(item.file) } catch { remaining.append(item); self.error = "Не удалось удалить временный файл." }
                }
                self.retiredItems = remaining; self.persistCaption()
            } catch {
                guard let self, self.bindingID == bound, self.preparationID == id, self.itemsRevision == revision, self.phase == .ready else { return }
                self.isRecoveryBusy = false; self.recoveryStatus = "Не удалось подтвердить сохранение набора. Повторите сохранение перед отправкой."
                self.recoveryRetry = { [weak self] in self?.persistItems(previousIDs: previousIDs, previousGrouping: previousGrouping) }
            }
        }
    }
    @Published public private(set) var videoCoverRevision = UUID()
    @Published public private(set) var videoCoverEditingID: UUID?
    @Published private var videoCoverWriteRevision: UUID?
    public var isVideoCoverSaving: Bool { videoCoverWriteRevision != nil }
    public var canEditVideoCover: Bool {
        phase == .ready && file?.mode == .video && target != nil && provider?.accountID == target?.accountID &&
            videoCoverEditingID == nil && !isVideoCoverSaving && !isRecoveryBusy &&
            (recoveryStore == nil ? !requiresRecovery : recoveryPrepared && recoveryStore?.accountID == target?.accountID)
    }
    public func beginVideoCoverEdit(contextID: UUID, revision: UUID) -> UUID? {
        guard preparationID == contextID, videoCoverRevision == revision, canEditVideoCover else { return nil }
        videoPlayback.stop()
        let id = UUID(); videoCoverEditingID = id
        return id
    }
    public func cancelVideoCoverEdit(_ editID: UUID) {
        guard videoCoverEditingID == editID else { return }
        videoCoverEditingID = nil; videoCoverRevision = UUID()
    }
    /// A true return transfers ownership of the new cover to this preparation.
    @discardableResult public func commitVideoCover(_ cover: TelegramUploadVideoCover?, editID: UUID) -> Bool {
        guard videoCoverEditingID == editID, phase == .ready, !isRecoveryBusy,
              let id = preparationID, let original = file, original.mode == .video,
              let target, provider?.accountID == target.accountID,
              recoveryStore == nil ? !requiresRecovery : recoveryPrepared && recoveryStore?.accountID == target.accountID else { return false }
        if let cover {
            guard cover.id != original.id, (try? TelegramUploadVideoCoverIO.validatedBytes(cover)) != nil else {
                error = "Не удалось применить обложку. Выберите изображение заново."; return false
            }
        }
        videoCoverEditingID = nil; videoCoverRevision = UUID(); videoPlayback.stop(); error = nil
        file = TelegramUploadFile(id: original.id, name: original.name, size: original.size, mode: original.mode,
            pixelWidth: original.pixelWidth, pixelHeight: original.pixelHeight, url: original.url, directory: original.directory,
            video: original.video, videoCover: cover)
        if let old = original.videoCover, old.id != cover?.id {
            do { try discard(old.imageFile) }
            catch { self.error = "Не удалось удалить временную копию предыдущей обложки." }
        }
        if let store = recoveryStore {
            videoCoverWriteRevision = videoCoverRevision
            persistVideoCover(store: store, original: original, cover: cover, target: target,
                id: id, bound: bindingID, revision: videoCoverRevision, itemID: usesBatchRecovery ? selectedItemID : nil)
        }
        return true
    }
    private func persistVideoCover(store: any TelegramUploadRecoveryStore, original: TelegramUploadFile,
                                   cover: TelegramUploadVideoCover?, target: TelegramUploadTarget,
                                   id: UUID, bound: UUID, revision: UUID, itemID: UUID?) {
        guard bindingID == bound, preparationID == id, videoCoverWriteRevision == revision, phase == .ready else { return }
        isRecoveryBusy = true; recoveryPrepared = false; recoveryRetry = nil
        recoveryStatus = "Сохраняем обложку…"
        let input = captionInput, above = captionAboveMedia, spoiler = mediaSpoiler
        Task { [weak self] in
            guard self?.bindingID == bound, self?.preparationID == id, self?.videoCoverWriteRevision == revision else { return }
            do {
                if let itemID {
                    try await store.replaceVideoCover(preparationID: id, itemID: itemID, file: original, target: target, cover: cover)
                } else {
                    try await store.replaceVideoCover(preparationID: id, file: original, target: target, cover: cover)
                }
                // A previous caption/options write may have failed. Confirm the
                // visible snapshot as well before this preparation can send.
                try await store.save(preparationID: id, chatID: target.chatID, captionInput: input,
                    captionAboveMedia: above, mediaSpoiler: spoiler, disposition: .prepared)
                guard let self, self.bindingID == bound, self.preparationID == id,
                      self.videoCoverWriteRevision == revision, self.phase == .ready else { return }
                self.videoCoverWriteRevision = nil; self.isRecoveryBusy = false; self.recoveryPrepared = true
                self.recoveryStatus = nil; self.recoveryRetry = nil
            } catch {
                guard let self, self.bindingID == bound, self.preparationID == id,
                      self.videoCoverWriteRevision == revision, self.phase == .ready else { return }
                self.isRecoveryBusy = false; self.recoveryPrepared = false
                self.recoveryStatus = "Не удалось подтвердить сохранение обложки. Повторите сохранение перед отправкой."
                self.recoveryRetry = { [weak self] in
                    self?.persistVideoCover(store: store, original: original, cover: cover, target: target,
                        id: id, bound: bound, revision: revision, itemID: itemID)
                }
            }
        }
    }
    public let videoPlayback = TelegramUploadVideoPlaybackController()
    public func openVideoPreview(contextID: UUID) async {
        guard preparationID == contextID, phase == .ready, !mediaSpoiler, videoCoverEditingID == nil, !isVideoCoverSaving,
              let file, file.mode == .video, file.videoCover == nil else { return }
        await videoPlayback.load(file)
    }
    public func stopVideoPreview(contextID: UUID) {
        guard preparationID == contextID else { return }
        videoPlayback.stop()
    }
    @Published public private(set) var phase: TelegramUploadPhase = .idle
    public private(set) var file: TelegramUploadFile? {
        get { items.first(where: { $0.id == selectedItemID })?.file ?? items.first?.file }
        set {
            guard let newValue else { items = []; selectedItemID = nil; return }
            if let index = items.firstIndex(where: { $0.id == selectedItemID }) {
                items[index] = .init(id: items[index].id, file: newValue)
            } else { items = [.init(id: newValue.id, file: newValue)]; selectedItemID = newValue.id }
        }
    }
    @Published public private(set) var target: TelegramUploadTarget?
    @Published public private(set) var captionInput: TelegramComposerInput = .empty
    @Published public private(set) var mediaSpoiler = false
    @discardableResult
    public func updateMediaSpoiler(_ spoiler: Bool, contextID: UUID, revision: UUID) -> Bool {
        guard token == contextID, captionRevision == revision, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving,
              isVisualMedia else { return false }
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
        guard token == contextID, captionRevision == revision, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving,
              isVisualMedia else { return false }
        if captionAboveMedia != above {
            captionAboveMedia = above; captionRevision = UUID(); persistCaption()
        }
        return true
    }
    public var caption: String {
        get { captionInput.formattedText.text }
        set {
            guard videoCoverEditingID == nil, !isVideoCoverSaving else { return }
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
    public var canSend: Bool { phase == .ready && videoCoverEditingID == nil && !isVideoCoverSaving && !isRecoveryBusy && ((!usesBatchRecovery && !requiresRecovery && recoveryStore == nil) || recoveryPrepared) && provider?.accountID == target?.accountID && telegramFormattedCaptionCanSend(captionInput.formattedText) }
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
              isVisualMedia, canSend else { return }
        send(spoilerOverride: true)
    }

    public func dismissPreparation(contextID: UUID) {
        guard preparationID == contextID else { return }
        if canCancel { cancelPreparation(); clear() }
        else if phase == .uncertain { clear() }
    }

    @discardableResult
    public func updateCaptionInput(_ input: TelegramComposerInput, contextID: UUID) -> Bool {
        guard token == contextID, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving else { return false }
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
        let batchItems = usesBatchRecovery ? items : nil, grouped = isGrouped
        if let store = recoveryStore, let id = preparationID {
            let bound = bindingID
            isRecoveryBusy = true; recoveryRetry = nil
            phase = .storing
            Task { [weak self] in
                guard self?.bindingID == bound, self?.preparationID == id, self?.phase == .storing else { return }
                do {
                    try await store.save(preparationID: id, chatID: target.chatID, captionInput: frozen, captionAboveMedia: frozenAbove, mediaSpoiler: frozenSpoiler, disposition: .submissionStarted)
                    if let batchItems {
                        guard let batchProvider = provider as? any TelegramUploadBatchProvider,
                              let draft = try await store.load(chatID: target.chatID), draft.schemaVersion == 6,
                              draft.id == id, draft.disposition == .submissionStarted,
                              draft.items.map(\.id) == batchItems.map(\.id), draft.isGrouped == grouped,
                              draft.captionInput == frozen, draft.captionAboveMedia == frozenAbove, draft.mediaSpoiler == frozenSpoiler else {
                            throw TelegramPendingUploadPersistenceError.conflict
                        }
                        guard let self, self.bindingID == bound, self.preparationID == id, self.phase == .storing else { return }
                        self.isRecoveryBusy = false
                        self.dispatchBatch(provider: batchProvider, store: store, items: batchItems, draft: draft, target: target)
                        return
                    }
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
        } else if !requiresRecovery && !usesBatchRecovery { dispatch(provider: provider, file: file, target: target, frozen: frozen, above: frozenAbove, spoiler: frozenSpoiler) }
    }

    private func dispatchBatch(provider: any TelegramUploadBatchProvider, store: any TelegramUploadRecoveryStore,
                               items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget) {
        let request = UUID(); token = request; committed = false; messageID = nil; messageIDs = []; acceptancePending = false
        sentInput = draft.captionInput; sentCaption = draft.captionInput.formattedText
        sentCaptionAboveMedia = draft.captionAboveMedia; sentMediaSpoiler = draft.mediaSpoiler
        phase = .storing; error = nil
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.token == request else { return }; self.expireSubmission()
        }
        willSubmit?(target, sentCaption)
        guard token == request, phase == .storing else { return }
        let returned = provider.submit(items: items, draft: draft, target: target) { [weak self] event in
            guard let self, self.token == request else { return }
            switch event {
            case .committing: self.receive(.committing)
            case let .accepted(ids):
                guard self.committed, self.messageIDs.isEmpty, !ids.isEmpty else { return }
                self.messageIDs = ids.map(\.description); self.messageID = self.messageIDs.first; self.acceptancePending = true
                self.deadline?.cancel(); self.deadline = nil
                self.confirmBatchAcceptance(store: store, draft: draft, ids: ids, bound: self.bindingID)
            case let .progress(progress): self.receive(.progress(progress))
            case .queueFailed: self.receive(.queueFailed)
            case .rejected: self.receive(.rejected)
            case .uncertain: self.receive(.uncertain)
            }
        }
        if token == request, phase != .rejected, phase != .cancelled, phase != .failed { lease = returned }
        else { returned.stop() }
    }

    private func confirmBatchAcceptance(store: any TelegramUploadRecoveryStore, draft: TelegramPendingUploadDraft,
                                        ids: [TelegramUploadQueueID], bound: UUID) {
        isRecoveryBusy = true; recoveryRetry = nil
        Task { [weak self] in
            do {
                guard let accepted = try await store.load(chatID: draft.chatID), accepted.id == draft.id,
                      accepted.schemaVersion == 6, accepted.accountID == draft.accountID, accepted.chatID == draft.chatID,
                      accepted.title == draft.title, accepted.items == draft.items, accepted.isGrouped == draft.isGrouped,
                      accepted.captionInput == draft.captionInput, accepted.captionAboveMedia == draft.captionAboveMedia,
                      accepted.mediaSpoiler == draft.mediaSpoiler, accepted.originalDraft == draft.originalDraft,
                      accepted.replyTarget == draft.replyTarget, accepted.disposition == .acceptedBatch(messageIDs: ids) else {
                    throw TelegramPendingUploadPersistenceError.conflict
                }
                guard let self, self.bindingID == bound, self.preparationID == draft.id, self.messageIDs == ids.map(\.description) else { return }
                self.isRecoveryBusy = false; self.recoveryStatus = nil; self.acknowledgeAccepted()
            } catch {
                guard let self, self.bindingID == bound, self.preparationID == draft.id, self.messageIDs == ids.map(\.description) else { return }
                self.isRecoveryBusy = false; self.phase = .uncertain
                self.recoveryStatus = "Не удалось подтвердить весь набор в очереди. Повтор отправки запрещён."
                self.recoveryRetry = { [weak self] in self?.confirmBatchAcceptance(store: store, draft: draft, ids: ids, bound: bound) }
            }
        }
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
        videoCoverEditingID = nil; videoCoverWriteRevision = nil; videoCoverRevision = UUID()
        // Rebinding detaches UI observation, not the user's latest preparation.
        // The original initial-write task consumes this snapshot on completion.
        if recoveryInitialInFlight, let id = preparationID, cancelledRecoveryContents[id] == nil {
            detachedInitialContents[id] = (captionInput, captionAboveMedia, mediaSpoiler)
        } else if phase == .ready, recoveryPrepared || usesBatchRecovery, let id = preparationID, let target, let store = recoveryStore,
                  !cancellationStarted.contains(id) {
            persistDetachedPreparation(store: store, id: id, chatID: target.chatID,
                input: captionInput, above: captionAboveMedia, spoiler: mediaSpoiler)
        }
        let possiblyQueued = committed || messageID != nil || phase == .uncertain
        token = UUID(); preparation?.cancel(); deadline?.cancel(); deadline = nil
        let old = lease; lease = nil; old?.stop()
        let cleaned = releaseStage(); target = nil; captionInput = .empty; messageID = nil; messageIDs = []; committed = false
        usesBatchRecovery = false; isGrouped = false; itemsRevision = UUID()
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
            acceptancePending = true; messageID = id; messageIDs = [id]
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
                                original: TelegramComposerDraft?, id: UUID, bound: UUID, store: (any TelegramUploadRecoveryStore)?, above: Bool, spoiler: Bool,
                                batchItems: [TelegramUploadBatchItem]? = nil, grouped: Bool = false) {
        guard let store, store.accountID == target.accountID else {
            recoveryPrepared = false; recoveryStatus = "Настройте хранилище вложений для сохранения перед отправкой."
            recoveryRetry = nil
            return
        }
        isRecoveryBusy = true; recoveryInitialInFlight = true; recoveryRetry = nil
        let discard = self.discard, cancellationPresentation = cancellationPresentationID
        let staged = batchItems ?? [.init(id: file.id, file: file)]
        Task { [weak self] in
            do {
                if let batchItems {
                    try await store.prepare(preparationID: id, items: batchItems, isGrouped: grouped, target: target,
                        captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, originalDraft: original)
                } else {
                    try await store.prepare(preparationID: id, file: file, target: target, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, originalDraft: original)
                }
                if let cancelled = self?.cancelledRecoveryContents.removeValue(forKey: id) {
                    self?.persistCancellation(store: store, id: id, chatID: target.chatID, input: cancelled.input, bound: bound, above: cancelled.above, spoiler: cancelled.spoiler, presentation: cancellationPresentation)
                }
                self?.persistDetachedInitialIfNeeded(store: store, id: id, chatID: target.chatID)
                guard let self, self.bindingID == bound, self.preparationID == id else { for item in staged { try? discard(item.file) }; return }
                self.recoveryInitialInFlight = false; self.isRecoveryBusy = false; self.recoveryPrepared = true; self.recoveryStatus = nil
                if self.captionInput != input || self.captionAboveMedia != above || self.mediaSpoiler != spoiler { self.persistCaption() }
            } catch {
                if let cancelled = self?.cancelledRecoveryContents.removeValue(forKey: id) {
                    self?.persistCancellation(store: store, id: id, chatID: target.chatID, input: cancelled.input, bound: bound, above: cancelled.above, spoiler: cancelled.spoiler, presentation: cancellationPresentation)
                }
                self?.persistDetachedInitialIfNeeded(store: store, id: id, chatID: target.chatID)
                guard let self, self.bindingID == bound, self.preparationID == id else { for item in staged { try? discard(item.file) }; return }
                self.recoveryInitialInFlight = false; self.isRecoveryBusy = false; self.recoveryPrepared = false
                self.recoveryStatus = "Не удалось сохранить вложение. Отправка заблокирована."
                self.recoveryRetry = { [weak self] in self?.persistInitial(file: file, target: target, input: input, original: original, id: id, bound: bound, store: store, above: above, spoiler: spoiler, batchItems: batchItems, grouped: grouped) }
            }
        }
    }
    private func persistCaption() {
        guard let store = recoveryStore, recoveryPrepared, let id = preparationID, let target, phase == .ready else { return }
        let bound = bindingID, input = captionInput, above = captionAboveMedia, spoiler = mediaSpoiler, coverRevision = videoCoverRevision, itemRevision = itemsRevision
        Task { [weak self] in
            guard self?.bindingID == bound, self?.preparationID == id, self?.phase == .ready, self?.itemsRevision == itemRevision, self?.captionInput == input, self?.captionAboveMedia == above, self?.mediaSpoiler == spoiler else { return }
            do {
                try await store.save(preparationID: id, chatID: target.chatID, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, disposition: .prepared)
                guard let self, self.bindingID == bound, self.preparationID == id, self.itemsRevision == itemRevision, self.videoCoverRevision == coverRevision, self.captionInput == input, self.captionAboveMedia == above, self.mediaSpoiler == spoiler, self.phase == .ready else { return }
                self.recoveryStatus = nil; self.recoveryRetry = nil
            } catch {
                guard let self, self.bindingID == bound, self.preparationID == id, self.itemsRevision == itemRevision, self.videoCoverRevision == coverRevision, self.captionInput == input, self.captionAboveMedia == above, self.mediaSpoiler == spoiler, self.phase == .ready else { return }
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
    func restore(draft: TelegramPendingUploadDraft, items: [TelegramUploadBatchItem], target: TelegramUploadTarget, restorationEpoch: UUID) -> Bool {
        if draft.schemaVersion < 6 {
            guard items.count == 1, items[0].id == draft.items[0].id else { return false }
            return restore(draft: draft, file: items[0].file, target: target, restorationEpoch: restorationEpoch)
        }
        guard restorationEpoch == recoveryRestoreEpoch, phase == .idle, draft.isValid, draft.schemaVersion == 6,
              provider is any TelegramUploadBatchProvider, provider?.accountID == draft.accountID,
              recoveryStore?.accountID == draft.accountID, target.accountID == draft.accountID, target.chatID == draft.chatID,
              target.hasValidReplySource, detachedInitialContents[draft.id] == nil,
              !detachedRecoveryWrites.contains(draft.id), detachedRecoveryRetries[draft.id] == nil,
              items.count == draft.items.count, zip(items, draft.items).allSatisfy({ staged, saved in
                  staged.id == saved.id && staged.file.name.utf8.elementsEqual(saved.file.attachment.name.utf8) &&
                  staged.file.size == saved.file.plaintextByteCount && staged.file.mode.rawValue == saved.file.attachment.kind &&
                  staged.file.video == saved.video && telegramPendingUploadCoverMatches(saved.videoCover, staged.file.videoCover) &&
                  (try? TelegramUploadFileIO.validateOwnedStage(staged.file)) != nil &&
                  (staged.file.videoCover == nil || (try? TelegramUploadVideoCoverIO.validatedBytes(staged.file.videoCover!)) != nil)
              }) else { return false }
        switch draft.disposition {
        case .prepared:
            guard draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else { return false }
        case .submissionStarted: break
        case .accepted, .acceptedBatch, .cancelled: return false
        }
        token = UUID(); preparationID = draft.id; self.items = items; selectedItemID = items[0].id
        usesBatchRecovery = true; isGrouped = draft.isGrouped; itemsRevision = UUID()
        self.target = target; captionInput = draft.captionInput; captionAboveMedia = draft.captionAboveMedia
        mediaSpoiler = draft.mediaSpoiler; captionRevision = UUID()
        sentInput = draft.captionInput; sentCaption = draft.captionInput.formattedText
        sentCaptionAboveMedia = draft.captionAboveMedia; sentMediaSpoiler = draft.mediaSpoiler
        recoveryPrepared = true; committed = draft.disposition == .submissionStarted
        phase = committed ? .uncertain : .ready
        didRestore?(target, draft.originalDraft, draft.id)
        return true
    }
    @discardableResult
    func restore(draft: TelegramPendingUploadDraft, file: TelegramUploadFile, target: TelegramUploadTarget, restorationEpoch: UUID) -> Bool {
        // A load/file export may finish after a detached write has cleared its
        // pending marker. Only a snapshot begun in the current epoch can apply.
        guard restorationEpoch == recoveryRestoreEpoch, phase == .idle, draft.isValid, draft.schemaVersion < 6,
              provider?.accountID == draft.accountID,
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
        case .accepted, .acceptedBatch, .cancelled: return false
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
        var failed: [TelegramUploadBatchItem] = []
        for item in items + retiredItems {
            do { try discard(item.file) } catch { failed.append(item) }
        }
        items = failed; retiredItems = []
        if !items.contains(where: { $0.id == selectedItemID }) { selectedItemID = items.first?.id }
        if !failed.isEmpty { self.error = "Не удалось удалить временный файл." }
        return failed.isEmpty
    }
    isolated deinit {
        videoPlayback.stop(); preparation?.cancel(); deadline?.cancel(); lease?.stop()
        // The initial write task owns the captured whole set until it completes.
        if !recoveryInitialInFlight { for item in items + retiredItems { try? discard(item.file) } }
    }
}
