import Foundation
import MakoshCore
import Combine
import UniformTypeIdentifiers

public struct TelegramUploadTarget: Equatable, Sendable {
    public let accountID: Int64
    public let chatID: Int64
    public let title: String
    public let replySource: TelegramMessageActionSource?
    public let selectedThreadID: Int64?
    public var threadID: Int64? { selectedThreadID ?? replySource?.threadID }
    public init(accountID: Int64, chatID: Int64, title: String, replySource: TelegramMessageActionSource? = nil, selectedThreadID: Int64? = nil) {
        self.accountID = accountID; self.chatID = chatID; self.title = title
        self.replySource = replySource; self.selectedThreadID = selectedThreadID
    }
    var hasValidReplySource: Bool {
        if let selectedThreadID { guard selectedThreadID > 0, selectedThreadID <= Int64(Int32.max) else { return false } }
        guard let source = replySource else { return true }
        if let selectedThreadID { guard source.peerID == chatID, source.threadID == selectedThreadID else { return false } }
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
    case awaitingApproval, committing, accepted(String), progress(Double?), queueFailed, rejected, uncertain
}

@MainActor public final class TelegramUploadController: ObservableObject {
    @Published public private(set) var items: [TelegramUploadBatchItem] = []
    @Published public private(set) var itemsRevision = UUID()
    @Published public private(set) var selectedItemID: UUID?
    @Published public private(set) var isGrouped = false
    @Published public private(set) var presentation: TelegramUploadPresentation = .media
    @Published public private(set) var messageIDs: [String] = []
    private var usesBatchRecovery = false
    private var captionRules: TelegramUploadCaptionRules = .legacy
    private var captionPolicy: TelegramUploadCaptionPolicy?
    private var mediaRules: TelegramUploadMediaRules = .legacy
    private var preparingRecordedVoice = false
    private var preparingRecordedRoundVideo = false
    private var containsRecordedVoice: Bool {
        preparingRecordedVoice || items.contains(where: { $0.file.metadata?.voice != nil })
    }
    private var containsRecordedRoundVideo: Bool {
        preparingRecordedRoundVideo || items.contains(where: { $0.file.metadata?.roundVideo != nil })
    }
    private var containsRecordedMedia: Bool { containsRecordedVoice || containsRecordedRoundVideo }
    private var retiredItems: [TelegramUploadBatchItem] = []
    private var recoveredArchive: TelegramUploadArchiveIO.Archive?
    private var archiveDescriptor: TelegramPendingUploadArchive?
    public var canEditItems: Bool {
        usesBatchRecovery && presentation != .archive && !containsRecordedRoundVideo && phase == .ready && recoveryPrepared && !isRecoveryBusy &&
            videoCoverEditingID == nil && !isVideoCoverSaving
    }
    public var isVisualMedia: Bool { !containsRecordedRoundVideo && presentation == .media && !items.isEmpty && items.allSatisfy { $0.file.mode != .file } }
    public var canUseMediaOptions: Bool { !containsRecordedRoundVideo && presentation == .media && items.contains { $0.file.mode != .file } }
    public var canSwitchPresentation: Bool {
        usesBatchRecovery && !containsRecordedMedia && TelegramUploadBatchItem.allowsMedia(items, rules: mediaRules)
    }
    public var canUseFilePresentation: Bool {
        usesBatchRecovery && !containsRecordedMedia && !items.isEmpty &&
            items.allSatisfy { $0.file.mode != .photo || $0.originalFile != nil }
    }
    public var canUseArchivePresentation: Bool {
        usesBatchRecovery && captionRules != .legacy && !containsRecordedMedia && (2...TelegramUploadArchiveLimits.members).contains(items.count) &&
            items.allSatisfy { $0.sourceFacts != nil }
    }
    public var canEditPresentation: Bool {
        usesBatchRecovery && !containsRecordedMedia && phase == .ready && recoveryPrepared && !isRecoveryBusy &&
            videoCoverEditingID == nil && !isVideoCoverSaving
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
        guard presentation == .archive ? canUseArchivePresentation : presentation == .file ? canUseFilePresentation : canSwitchPresentation else { return false }
        let previousPresentation = self.presentation, previousGrouping = isGrouped
        videoPlayback.stop(); self.presentation = presentation
        if presentation == .archive { captionAboveMedia = false; mediaSpoiler = false }
        isGrouped = isGrouped && canGroupItems
        itemsRevision = UUID(); captionRevision = UUID(); videoCoverRevision = UUID()
        persistPresentation(previousPresentation: previousPresentation, previousGrouping: previousGrouping)
        return true
    }
    private func persistPresentation(previousPresentation: TelegramUploadPresentation, previousGrouping: Bool) {
        guard let store = recoveryStore, let id = preparationID, let target else { return }
        writePresentation(.init(store: store, id: id, target: target, binding: bindingID, revision: itemsRevision,
            previousIDs: nil, orderedIDs: items.map(\.id), previousPresentation: previousPresentation, previousGrouping: previousGrouping,
            presentation: presentation, isGrouped: isGrouped, cachedArchive: archiveDescriptor, captionPolicy: captionPolicy,
            input: captionInput, above: captionAboveMedia, spoiler: mediaSpoiler))
    }
    private struct PresentationWrite {
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
    private var presentationWrites: [UUID: PresentationWrite] = [:]
    private func isCurrent(_ write: PresentationWrite) -> Bool {
        bindingID == write.binding && preparationID == write.id && itemsRevision == write.revision && phase == .ready
    }
    private func finishPresentationWrite(_ id: UUID) {
        presentationWrites.removeValue(forKey: id); detachedRecoveryWrites.remove(id)
        detachedRecoveryRetries.removeValue(forKey: id); recoveryRestoreEpoch = UUID()
        updateDetachedRecoveryStatus()
    }
    private func writePresentation(_ write: PresentationWrite) {
        guard detachedRecoveryWrites.insert(write.id).inserted else { return }
        presentationWrites[write.id] = write; recoveryRestoreEpoch = UUID()
        detachedRecoveryRetries.removeValue(forKey: write.id)
        if isCurrent(write) {
            isRecoveryBusy = true; recoveryPrepared = false; recoveryRetry = nil
            recoveryStatus = write.previousIDs == nil ? "Сохраняем способ отправки…" : "Сохраняем набор вложений…"
        } else { updateDetachedRecoveryStatus() }
        Task { [weak self] in
            do {
                if let previousIDs = write.previousIDs {
                    try await write.store.updateItems(preparationID: write.id, previousIDs: previousIDs,
                        previousGrouping: write.previousGrouping, previousPresentation: write.previousPresentation,
                        orderedIDs: write.orderedIDs, isGrouped: write.isGrouped, presentation: write.presentation, target: write.target)
                } else {
                    try await write.store.updatePresentation(preparationID: write.id, orderedIDs: write.orderedIDs,
                        previousPresentation: write.previousPresentation, previousGrouping: write.previousGrouping,
                        presentation: write.presentation, isGrouped: write.isGrouped, target: write.target)
                }
                if let policy = write.captionPolicy {
                    guard let saved = try await write.store.load(chatID: write.target.chatID), saved.isValid,
                          saved.id == write.id, saved.accountID == write.target.accountID,
                          saved.chatID == write.target.chatID, saved.disposition == .prepared,
                          saved.items.map(\.id) == write.orderedIDs, saved.presentation == write.presentation,
                          saved.isGrouped == write.isGrouped, saved.captionPolicy == policy else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                }
                if write.presentation == .archive || write.previousPresentation == .archive || write.cachedArchive != nil {
                    let invalidated = write.previousIDs.map { $0 != write.orderedIDs } ?? false
                    guard let saved = try await write.store.load(chatID: write.target.chatID), saved.isValid,
                          saved.id == write.id, saved.accountID == write.target.accountID,
                          saved.chatID == write.target.chatID, saved.disposition == .prepared,
                          saved.items.map(\.id) == write.orderedIDs, saved.presentation == write.presentation,
                          saved.isGrouped == write.isGrouped else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                    if invalidated {
                        guard saved.archive == nil else { throw TelegramPendingUploadPersistenceError.conflict }
                    } else {
                        guard saved.archive != nil else { throw TelegramPendingUploadPersistenceError.conflict }
                        if let expected = write.cachedArchive {
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
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
                            self.recoveredArchive = bundle.archive; self.archiveDescriptor = saved.archive
                        } else { try await Self.discardBundle(bundle) }
                    } catch { try? await Self.discardBundle(bundle); throw error }
                }
                if let self, self.isCurrent(write) {
                    self.finishPresentationWrite(write.id)
                    self.isRecoveryBusy = false; self.recoveryPrepared = true; self.recoveryStatus = nil
                    if write.previousIDs != nil {
                        var remaining: [TelegramUploadBatchItem] = []
                        for item in self.retiredItems {
                            do { try item.discard(using: self.discard) } catch { remaining.append(item); self.error = "Не удалось удалить временный файл." }
                        }
                        self.retiredItems = remaining
                    }
                    self.persistCaption()
                } else {
                    // Rebinding may change the input while the original mode/list CAS is held.
                    // Its latest frozen tuple still belongs only to the original store.
                    if self?.cancellationStarted.contains(write.id) != true {
                        let frozen = self?.presentationWrites[write.id] ?? write
                        try await frozen.store.save(preparationID: frozen.id, chatID: frozen.target.chatID,
                            captionInput: frozen.input, captionAboveMedia: frozen.above, mediaSpoiler: frozen.spoiler, disposition: .prepared)
                    }
                    self?.finishPresentationWrite(write.id)
                }
            } catch {
                guard let self else { return }
                let frozen = self.presentationWrites[write.id] ?? write
                self.detachedRecoveryWrites.remove(write.id); self.recoveryRestoreEpoch = UUID()
                if self.cancellationStarted.contains(write.id) {
                    self.finishPresentationWrite(write.id)
                } else if self.isCurrent(write) {
                    self.isRecoveryBusy = false
                    self.recoveryStatus = write.previousIDs == nil
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
    private static func stageSelections(_ selected: [TelegramUploadSelection], photoSize: TelegramUploadPhotoSize,
                                        stage: (URL, TelegramUploadMode) async throws -> TelegramUploadFile,
                                        staged: inout [TelegramUploadBatchItem], isCurrent: () -> Bool) async throws {
        for source in selected {
            try Task.checkCancellation()
            if source.mode == .video {
                let file = try await stage(source.source, .video)
                staged.append(.init(id: file.id, file: file))
            } else {
                let original = source.mode == .photo
                    ? try await TelegramUploadFileIO.stage(source.source, mode: .file)
                    : try await stage(source.source, .file)
                // Own the raw copy before classification or derivative generation can suspend.
                staged.append(.init(id: original.id, file: original))
                let type = UTType(filenameExtension: (original.name as NSString).pathExtension)
                let photoCandidate = source.mode == .photo || type?.conforms(to: .image) == true
                let oggCandidate = try TelegramUploadAudioIO.hasOggSignature(original)
                do {
                    let webP = try await TelegramUploadWebPIO.inspect(original)
                    let selectedMIME = TelegramUploadSourceFactsIO.selectionMIME(for: original.name)
                    var selectedWebPPhoto = false
                    if webP != nil, selectedMIME.hasPrefix("image/"),
                       selectedMIME != "image/webp", !selectedMIME.hasSuffix("gif") {
                        selectedWebPPhoto = try await TelegramUploadPhotoEligibility.canPrepare(original,
                            photoSize: photoSize, allowsSelectedWebPPhoto: true)
                    }
                    if let webP, !selectedWebPPhoto {
                        let file = TelegramUploadFile(id: original.id, name: original.name, size: original.size,
                            mode: .file, pixelWidth: nil, pixelHeight: nil, url: original.url,
                            directory: original.directory, metadata: .webP(webP))
                        staged[staged.count - 1] = .init(id: original.id, file: file)
                    } else if let gif = try await TelegramUploadGIFIO.inspect(original) {
                        let capture = try await BackgroundWork.run { try TelegramPendingUploadFiles.captureFile(original) }
                        let digest = try await BackgroundWork.run { try capture.plaintextSHA256() }
                        let converted = try await TelegramUploadGIFIO.convert(original, expected: gif, expectedPlaintextSHA256: digest)
                        let file = TelegramUploadFile(id: converted.id, name: converted.name, size: converted.size,
                            mode: .video, pixelWidth: converted.pixelWidth, pixelHeight: converted.pixelHeight,
                            url: converted.url, directory: converted.directory, video: converted.video,
                            metadata: .gif(.init(width: gif.width, height: gif.height,
                                frameDurations: gif.frameDurations, sourceSHA256: digest)))
                        staged[staged.count - 1] = .init(id: original.id, file: file, originalFile: original)
                    } else if photoCandidate && !oggCandidate, try await TelegramUploadPhotoEligibility.canPrepare(original,
                        photoSize: photoSize, allowsSelectedWebPPhoto: selectedWebPPhoto) {
                        let jpeg = try await stage(original.url, .photo)
                        let name = telegramAttachmentName((original.name as NSString).deletingPathExtension + ".jpg")
                        let file = TelegramUploadFile(id: jpeg.id, name: name, size: jpeg.size, mode: jpeg.mode,
                            pixelWidth: jpeg.pixelWidth, pixelHeight: jpeg.pixelHeight, url: jpeg.url,
                            directory: jpeg.directory, video: jpeg.video, videoCover: jpeg.videoCover)
                        staged[staged.count - 1] = .init(id: original.id, file: file, originalFile: original)
                    } else if !oggCandidate && type?.preferredMIMEType?.hasPrefix("video/") == true {
                        do {
                            let info = try await TelegramUploadVideoIO.inspect(original)
                            let metadata = TelegramUploadVideoMetadata(width: info.width, height: info.height,
                                duration: info.duration, hasAudio: info.hasAudio, inCollage: true)
                            let file = TelegramUploadFile(id: original.id, name: original.name, size: original.size,
                                mode: .video, pixelWidth: info.width, pixelHeight: info.height,
                                url: original.url, directory: original.directory, video: metadata)
                            staged[staged.count - 1] = .init(id: original.id, file: file)
                        } catch TelegramUploadFileError.invalidVideo {
                            // An ordinary file choice remains usable when its video suffix is misleading.
                        }
                    } else if oggCandidate || type?.conforms(to: .audio) == true || type?.preferredMIMEType?.hasPrefix("audio/") == true {
                        do {
                            let audio = try await TelegramUploadAudioIO.inspect(original)
                            let file = TelegramUploadFile(id: original.id, name: original.name, size: original.size,
                                mode: .file, pixelWidth: nil, pixelHeight: nil, url: original.url,
                                directory: original.directory, metadata: .audio(audio))
                            staged[staged.count - 1] = .init(id: original.id, file: file)
                        } catch TelegramUploadFileError.invalidAudio {
                            // Unsupported or misleading containers retain their unchanged generic file.
                        }
                    }
                } catch TelegramUploadFileError.invalidWebP {
                    // Recognizable unsafe WebP remains an unchanged generic file, without suffix reinterpretation.
                } catch TelegramUploadGIFError.invalidGIF {
                    // Recognizable unsafe GIF retains the unchanged document, without suffix reinterpretation.
                }
            }
            let item = staged[staged.count - 1]
            let facts = try await TelegramUploadSourceFactsIO.inspect(itemID: item.id, raw: item.rawSource,
                role: item.originalFile == nil ? .prepared : .original, metadata: item.file.metadata)
            staged[staged.count - 1] = .init(id: item.id, file: item.file, originalFile: item.originalFile, sourceFacts: facts)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
    }
    public func prepare(sources: [TelegramUploadSelection], isGrouped: Bool, target: TelegramUploadTarget, captionInput: TelegramComposerInput,
                        photoSize: TelegramUploadPhotoSize = .standard, captionPolicy: TelegramUploadCaptionPolicy? = nil) {
        guard preparation == nil, phase == .idle || phase == .cancelled || phase == .failed || phase == .rejected,
              provider is any TelegramUploadBatchProvider, provider?.accountID == target.accountID, target.hasValidReplySource else { return }
        var seen: Set<URL> = []
        let selected = sources.filter { seen.insert($0.source.standardizedFileURL).inserted }
        guard !selected.isEmpty else { return }
        clear(); resetCancellationPresentation()
        guard items.isEmpty, recoveredArchive == nil else { phase = .failed; return }
        usesBatchRecovery = true; captionRules = captionPolicy == nil ? .reference : TelegramUploadCaptionRules.containsCustomEmoji(captionInput.formattedText) ? .extended : .current; mediaRules = .reference
        self.captionPolicy = captionPolicy
        self.target = target; self.captionInput = captionInput; phase = .preparing
        let request = token, bound = bindingID, discard = self.discard, store = recoveryStore
        let stage = self.stage ?? { source, mode in try await TelegramUploadFileIO.stage(source, mode: mode, photoSize: photoSize) }
        preparationID = request; didPrepare?(target, captionInput, request)
        guard token == request, phase == .preparing else { return }
        let original = originalDraftForRecovery?(target, request)
        preparation = Task { [weak self] in
            var staged: [TelegramUploadBatchItem] = []
            do {
                try await Self.stageSelections(selected, photoSize: photoSize, stage: stage, staged: &staged,
                    isCurrent: { [weak self] in self?.token == request })
                guard let self, self.token == request else { throw CancellationError() }
                var presentation = TelegramUploadSourceClassifier.initialPresentation(for: staged.compactMap(\.sourceFacts),
                    asMedia: selected.allSatisfy { $0.mode != .file })
                if presentation == .media && !TelegramUploadBatchItem.allowsMedia(staged, rules: self.mediaRules) { presentation = .file }
                let grouped = isGrouped && presentation.allowsGrouping(staged)
                self.sourceURLsByItemID = Dictionary(uniqueKeysWithValues: zip(staged, selected).map { ($0.0.id, $0.1.source.standardizedFileURL) })
                self.preparation = nil; self.items = staged; self.selectedItemID = staged[0].id
                self.presentation = presentation; self.isGrouped = grouped
                self.itemsRevision = UUID(); self.phase = .ready
                self.persistInitial(file: staged[0].file, target: target, input: captionInput, original: original,
                    id: request, bound: bound, store: store, above: false, spoiler: false, batchItems: staged, grouped: grouped)
            } catch {
                var cleanupFailed = false
                for item in staged { do { try item.discard(using: discard) } catch { cleanupFailed = true } }
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
    private var sourceURLsByItemID: [UUID: URL] = [:]
    public var isAppendingItems: Bool { appendOperationID != nil }
    private var appendOperationID: UUID?
    public var canAppendItems: Bool {
        usesBatchRecovery && mediaRules == .reference && !containsRecordedMedia && !items.isEmpty &&
            items.allSatisfy { $0.sourceFacts != nil } && phase == .ready && recoveryPrepared && !isRecoveryBusy &&
            videoCoverEditingID == nil && !isVideoCoverSaving && recoveryStore?.accountID == target?.accountID
    }
    private struct AppendWrite {
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
    private func isCurrent(_ write: AppendWrite) -> Bool {
        appendOperationID == write.operation && bindingID == write.binding && token == write.token && preparationID == write.id &&
            itemsRevision == write.revision && items.map(\.id) == write.previousIDs && target == write.target &&
            captionInput == write.input && captionAboveMedia == write.above && mediaSpoiler == write.spoiler &&
            presentation == write.presentation && isGrouped == write.grouped && captionPolicy == write.policy &&
            (phase == .preparing || phase == .ready)
    }
    /// Adds to the durable preparation; never replaces its existing resources or submits it.
    @discardableResult public func append(sources: [TelegramUploadSelection], contextID: UUID, revision: UUID,
                                         photoSize: TelegramUploadPhotoSize = .standard) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canAppendItems, preparation == nil,
              let target, let store = recoveryStore, provider?.accountID == target.accountID, target.hasValidReplySource,
              !sources.isEmpty, sources.allSatisfy({ $0.source.isFileURL &&
                  ($0.source.host == nil || $0.source.host == "" || $0.source.host == "localhost") }) else { return false }
        var seen = Set(sourceURLsByItemID.values)
        let selected = sources.filter { seen.insert($0.source.standardizedFileURL).inserted }
        guard !selected.isEmpty else { return false }
        let write = AppendWrite(operation: UUID(), store: store, id: contextID, target: target, binding: bindingID, token: token,
            revision: revision, previousIDs: items.map(\.id), input: captionInput, above: captionAboveMedia,
            spoiler: mediaSpoiler, presentation: presentation, grouped: isGrouped, policy: captionPolicy, sources: selected.map { $0.source.standardizedFileURL })
        let stage = self.stage ?? { source, mode in try await TelegramUploadFileIO.stage(source, mode: mode, photoSize: photoSize) }
        let discard = self.discard
        appendOperationID = write.operation
        phase = .preparing; isRecoveryBusy = true; error = nil; recoveryRetry = nil
        recoveryStatus = "Добавляем файлы…"; videoPlayback.stop()
        preparation = Task { [weak self] in
            var staged: [TelegramUploadBatchItem] = []
            var capture: TelegramUploadAppendCapture?
            do {
                // Complete the entire new selection before touching the old pointer.
                try await Self.stageSelections(selected, photoSize: photoSize, stage: stage, staged: &staged,
                    isCurrent: { [weak self] in self?.isCurrent(write) == true })
                guard self?.isCurrent(write) == true else { throw CancellationError() }
                try await store.save(preparationID: write.id, chatID: target.chatID, captionInput: write.input,
                    captionAboveMedia: write.above, mediaSpoiler: write.spoiler, disposition: .prepared)
                try Task.checkCancellation()
                guard self?.isCurrent(write) == true,
                      let snapshot = try await store.load(chatID: target.chatID), snapshot.isValid,
                      snapshot.id == write.id, snapshot.accountID == target.accountID, snapshot.chatID == target.chatID,
                      [17, 18, 19].contains(snapshot.resourceSchemaVersion), snapshot.disposition == .prepared,
                      snapshot.items.map(\.id) == write.previousIDs, snapshot.captionInput == write.input,
                      snapshot.captionAboveMedia == write.above, snapshot.mediaSpoiler == write.spoiler,
                      snapshot.presentation == write.presentation, snapshot.isGrouped == write.grouped,
                      snapshot.captionPolicy == write.policy else { throw TelegramPendingUploadPersistenceError.conflict }
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
                self.isRecoveryBusy = false; self.phase = .ready
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
    private func retryAppend(_ capture: TelegramUploadAppendCapture, write: AppendWrite) {
        guard isCurrent(write), phase == .ready, !isRecoveryBusy, preparation == nil else { return }
        phase = .preparing; isRecoveryBusy = true; recoveryRetry = nil
        preparation = Task { [weak self] in
            guard let self else { return }
            do { try await self.installAppended(capture, write: write) }
            catch {
                guard self.isCurrent(write) else { return }
                self.preparation = nil; self.phase = .ready; self.isRecoveryBusy = false; self.recoveryPrepared = false
                self.recoveryStatus = "Не удалось подтвердить добавление файлов. Повторите сохранение или закройте подготовку."
                self.recoveryRetry = { [weak self] in self?.retryAppend(capture, write: write) }
            }
        }
    }
    private func installAppended(_ capture: TelegramUploadAppendCapture, write: AppendWrite) async throws {
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
                return Self.matchesItems(bundle.items, draft: saved) && (saved.archive == nil
                    ? bundle.archive == nil : Self.matchesArchive(bundle.archive, draft: saved))
            }
            guard !Task.isCancelled, isCurrent(write), valid else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            let old = items + retiredItems, oldArchive = recoveredArchive
            items = bundle.items; retiredItems = []; recoveredArchive = bundle.archive; archiveDescriptor = saved.archive
            selectedItemID = bundle.items.last?.id
            for (item, source) in zip(bundle.items.suffix(write.sources.count), write.sources) { sourceURLsByItemID[item.id] = source }
            captionPolicy = saved.captionPolicy; captionRules = saved.captionRules; mediaRules = saved.mediaRules
            presentation = saved.presentation; isGrouped = saved.isGrouped
            itemsRevision = UUID(); captionRevision = UUID(); videoCoverRevision = UUID()
            appendOperationID = nil; preparation = nil; phase = .ready; isRecoveryBusy = false; recoveryPrepared = true
            recoveryStatus = nil; recoveryRetry = nil; error = nil
            for item in old {
                do { try item.discard(using: discard) }
                catch { retiredItems.append(item); self.error = "Не удалось удалить временные файлы." }
            }
            if let oldArchive {
                do { try discard(oldArchive.file) }
                catch { retiredItems.append(.init(id: oldArchive.file.id, file: oldArchive.file)); self.error = "Не удалось удалить временный файл." }
            }
        } catch { try? await Self.discardBundle(bundle); throw error }
    }
    private nonisolated static func discardBundle(_ bundle: TelegramRecoveredUploadBundle) async throws {
        try await Task.detached(priority: .utility) { try bundle.discard() }.value
    }
    @discardableResult public func moveItem(id: UUID, to index: Int, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditItems,
              items.indices.contains(index), let oldIndex = items.firstIndex(where: { $0.id == id }) else { return false }
        if oldIndex == index { return true }
        let oldIDs = items.map(\.id), oldGrouping = isGrouped, oldPresentation = presentation
        let item = items.remove(at: oldIndex); items.insert(item, at: index)
        normalizePresentationAfterItemEdit()
        itemsRevision = UUID(); persistItems(previousIDs: oldIDs, previousGrouping: oldGrouping, previousPresentation: oldPresentation)
        return true
    }
    @discardableResult public func removeItem(id: UUID, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditItems,
              let index = items.firstIndex(where: { $0.id == id }) else { return false }
        if items.count == 1 { cancelPreparation(); return true }
        let oldIDs = items.map(\.id), oldGrouping = isGrouped, oldPresentation = presentation
        sourceURLsByItemID.removeValue(forKey: id)
        retiredItems.append(items.remove(at: index)); videoPlayback.stop()
        if selectedItemID == id { selectedItemID = items[min(index, items.count - 1)].id; videoCoverRevision = UUID() }
        normalizePresentationAfterItemEdit()
        itemsRevision = UUID(); persistItems(previousIDs: oldIDs, previousGrouping: oldGrouping, previousPresentation: oldPresentation)
        return true
    }
    private func normalizePresentationAfterItemEdit() {
        if let captionPolicy { self.captionPolicy = try? captionPolicy.reordered(items.map(\.id)) }
        if presentation == .media && !TelegramUploadBatchItem.allowsMedia(items, rules: mediaRules) {
            presentation = .file; captionRevision = UUID(); videoCoverRevision = UUID()
        }
        isGrouped = isGrouped && canGroupItems
    }
    @discardableResult public func updateGrouping(_ grouped: Bool, contextID: UUID, revision: UUID) -> Bool {
        guard preparationID == contextID, itemsRevision == revision, canEditItems, !grouped || canGroupItems else { return false }
        if isGrouped == grouped { return true }
        let oldGrouping = isGrouped; isGrouped = grouped; itemsRevision = UUID()
        persistItems(previousIDs: items.map(\.id), previousGrouping: oldGrouping, previousPresentation: presentation)
        return true
    }
    @discardableResult public func selectItem(id: UUID, contextID: UUID) -> Bool {
        guard preparationID == contextID, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving,
              items.contains(where: { $0.id == id }) else { return false }
        if selectedItemID != id { videoPlayback.stop(); selectedItemID = id; videoCoverRevision = UUID() }
        return true
    }
    private func persistItems(previousIDs: [UUID], previousGrouping: Bool, previousPresentation: TelegramUploadPresentation) {
        guard let store = recoveryStore, let id = preparationID, let target else { return }
        writePresentation(.init(store: store, id: id, target: target, binding: bindingID, revision: itemsRevision,
            previousIDs: previousIDs, orderedIDs: items.map(\.id), previousPresentation: previousPresentation,
            previousGrouping: previousGrouping, presentation: presentation, isGrouped: isGrouped, cachedArchive: archiveDescriptor, captionPolicy: captionPolicy,
            input: captionInput, above: captionAboveMedia, spoiler: mediaSpoiler))
    }
    @Published public private(set) var videoCoverRevision = UUID()
    @Published public private(set) var videoCoverEditingID: UUID?
    @Published private var videoCoverWriteRevision: UUID?
    public var isVideoCoverSaving: Bool { videoCoverWriteRevision != nil }
    public var canEditVideoCover: Bool {
        phase == .ready && file?.mode == .video && file?.metadata?.gif == nil && !containsRecordedRoundVideo && target != nil && provider?.accountID == target?.accountID &&
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
    @discardableResult public func commitVideoCover(_ cover: TelegramUploadVideoCover?, editID: UUID) async -> Bool {
        guard videoCoverEditingID == editID, phase == .ready, !isRecoveryBusy,
              let id = preparationID, let original = file, original.mode == .video, original.metadata?.roundVideo == nil,
              let target, provider?.accountID == target.accountID,
              recoveryStore == nil ? !requiresRecovery : recoveryPrepared && recoveryStore?.accountID == target.accountID else { return false }
        let bound = bindingID, request = token, revision = videoCoverRevision, itemRevision = itemsRevision
        let itemID = selectedItemID, validate = willValidateUpload
        @MainActor func current() -> Bool {
            !Task.isCancelled && bindingID == bound && token == request && preparationID == id &&
                videoCoverEditingID == editID && videoCoverRevision == revision && itemsRevision == itemRevision &&
                selectedItemID == itemID && file == original && self.target == target && phase == .ready && !isRecoveryBusy &&
                provider?.accountID == target.accountID &&
                (recoveryStore == nil ? !requiresRecovery : recoveryPrepared && recoveryStore?.accountID == target.accountID)
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
        videoCoverEditingID = nil; videoCoverRevision = UUID(); videoPlayback.stop(); error = nil
        file = TelegramUploadFile(id: original.id, name: original.name, size: original.size, mode: original.mode,
            pixelWidth: original.pixelWidth, pixelHeight: original.pixelHeight, url: original.url, directory: original.directory,
            video: original.video, videoCover: cover, metadata: original.metadata)
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
    /// The write retains its candidate path until real capture/save completes,
    /// independently of the observed account or the controller's lifetime.
    @MainActor private final class VideoCoverWrite {
        let store: any TelegramUploadRecoveryStore
        let original: TelegramUploadFile
        let cover: TelegramUploadVideoCover?
        let target: TelegramUploadTarget
        let id: UUID
        let binding: UUID
        let revision: UUID
        let itemID: UUID?
        let input: TelegramComposerInput
        let above: Bool
        let spoiler: Bool
        var isRunning = false
        var detached = false
        init(store: any TelegramUploadRecoveryStore, original: TelegramUploadFile, cover: TelegramUploadVideoCover?,
             target: TelegramUploadTarget, id: UUID, binding: UUID, revision: UUID, itemID: UUID?,
             input: TelegramComposerInput, above: Bool, spoiler: Bool) {
            self.store = store; self.original = original; self.cover = cover; self.target = target
            self.id = id; self.binding = binding; self.revision = revision; self.itemID = itemID
            self.input = input; self.above = above; self.spoiler = spoiler
        }
        isolated deinit {
            if detached, let cover {
                Task.detached(priority: .utility) { try? TelegramUploadFileIO.discard(cover.imageFile) }
            }
        }
    }
    private var videoCoverWrites: [UUID: VideoCoverWrite] = [:]
    private func isCurrent(_ write: VideoCoverWrite) -> Bool {
        bindingID == write.binding && preparationID == write.id && videoCoverWriteRevision == write.revision && phase == .ready
    }
    private func persistVideoCover(store: any TelegramUploadRecoveryStore, original: TelegramUploadFile,
                                   cover: TelegramUploadVideoCover?, target: TelegramUploadTarget,
                                   id: UUID, bound: UUID, revision: UUID, itemID: UUID?) {
        guard bindingID == bound, preparationID == id, videoCoverWriteRevision == revision, phase == .ready else { return }
        let write = VideoCoverWrite(store: store, original: original, cover: cover, target: target, id: id,
            binding: bound, revision: revision, itemID: itemID, input: captionInput, above: captionAboveMedia, spoiler: mediaSpoiler)
        // Register ownership synchronously, before the task's first opportunity to suspend.
        videoCoverWrites[id] = write
        persistVideoCover(write)
    }
    private func persistVideoCover(_ write: VideoCoverWrite) {
        guard videoCoverWrites[write.id] === write, !write.isRunning, !cancellationStarted.contains(write.id) else { return }
        write.isRunning = true
        detachedRecoveryWrites.insert(write.id); detachedRecoveryRetries.removeValue(forKey: write.id)
        recoveryRestoreEpoch = UUID()
        if isCurrent(write) {
            isRecoveryBusy = true; recoveryPrepared = false; recoveryRetry = nil
            recoveryStatus = "Сохраняем обложку…"
        } else { updateDetachedRecoveryStatus() }
        Task { [weak self, write] in
            do {
                if let itemID = write.itemID {
                    try await write.store.replaceVideoCover(preparationID: write.id, itemID: itemID, file: write.original,
                        target: write.target, cover: write.cover)
                } else {
                    try await write.store.replaceVideoCover(preparationID: write.id, file: write.original,
                        target: write.target, cover: write.cover)
                }
                // Confirm the visible caption/options too before sending can resume.
                try await write.store.save(preparationID: write.id, chatID: write.target.chatID, captionInput: write.input,
                    captionAboveMedia: write.above, mediaSpoiler: write.spoiler, disposition: .prepared)
                guard let self, self.videoCoverWrites[write.id] === write else { return }
                let current = self.isCurrent(write)
                self.videoCoverWrites.removeValue(forKey: write.id)
                self.detachedRecoveryWrites.remove(write.id); self.detachedRecoveryRetries.removeValue(forKey: write.id)
                self.recoveryRestoreEpoch = UUID(); write.isRunning = false
                if current {
                    self.videoCoverWriteRevision = nil; self.isRecoveryBusy = false; self.recoveryPrepared = true
                    self.recoveryStatus = nil; self.recoveryRetry = nil
                }
                self.updateDetachedRecoveryStatus()
            } catch {
                guard let self, self.videoCoverWrites[write.id] === write else { return }
                write.isRunning = false
                self.detachedRecoveryWrites.remove(write.id); self.recoveryRestoreEpoch = UUID()
                if self.cancellationStarted.contains(write.id) {
                    self.videoCoverWrites.removeValue(forKey: write.id)
                    self.detachedRecoveryRetries.removeValue(forKey: write.id)
                } else if self.isCurrent(write) {
                    self.isRecoveryBusy = false; self.recoveryPrepared = false
                    self.recoveryStatus = "Не удалось подтвердить сохранение обложки. Повторите сохранение перед отправкой."
                    self.recoveryRetry = { [weak self, write] in self?.persistVideoCover(write) }
                } else {
                    self.detachedRecoveryRetries[write.id] = { [weak self, write] in self?.persistVideoCover(write) }
                }
                self.updateDetachedRecoveryStatus()
            }
        }
    }
    public let videoPlayback = TelegramUploadVideoPlaybackController()
    public func openVideoPreview(contextID: UUID) async {
        guard preparationID == contextID, phase == .ready, !mediaSpoiler, videoCoverEditingID == nil, !isVideoCoverSaving,
              let file, file.mode == .video, file.metadata?.roundVideo == nil, file.videoCover == nil else { return }
        await videoPlayback.load(file)
    }
    /// Explicit round preparation keeps the ordinary-video preview boundary closed.
    public func openRoundVideoPreview(contextID: UUID) async {
        guard preparationID == contextID, phase == .ready, containsRecordedRoundVideo,
              items.count == 1, presentation == .media, !mediaSpoiler,
              videoCoverEditingID == nil, !isVideoCoverSaving,
              let file, file.metadata?.roundVideo != nil, file.videoCover == nil else { return }
        await videoPlayback.loadRoundVideo(file)
    }
    public func stopVideoPreview(contextID: UUID) {
        guard preparationID == contextID else { return }
        videoPlayback.stop()
    }
    @Published public private(set) var phase: TelegramUploadPhase = .idle
    public private(set) var file: TelegramUploadFile? {
        get {
            if presentation == .archive { return recoveredArchive?.file }
            return (items.first(where: { $0.id == selectedItemID }) ?? items.first)?.presented(as: presentation)?.file
        }
        set {
            guard let newValue else { items = []; selectedItemID = nil; return }
            if let index = items.firstIndex(where: { $0.id == selectedItemID }) {
                items[index] = .init(id: items[index].id, file: newValue, originalFile: items[index].originalFile,
                    sourceFacts: items[index].sourceFacts)
            } else { items = [.init(id: newValue.id, file: newValue)]; selectedItemID = newValue.id }
        }
    }
    @Published public private(set) var target: TelegramUploadTarget?
    @Published public private(set) var captionInput: TelegramComposerInput = .empty
    @Published public private(set) var captionCustomEmojiInsertion: TelegramCustomEmojiInsertionRequest?
    private struct CaptionEmojiInsertion {
        let request: TelegramCustomEmojiInsertionRequest
        let catalog: TelegramCustomEmojiCatalogController
        let catalogContextID: UUID
        let preparationID: UUID
        let captionRevision: UUID
        let itemsRevision: UUID
        let target: TelegramUploadTarget
        let bindingID: UUID
    }
    private var pendingCaptionEmojiInsertion: CaptionEmojiInsertion?
    public var canInsertCaptionCustomEmoji: Bool {
        phase == .ready && recoveryPrepared && !isRecoveryBusy && appendOperationID == nil &&
            videoCoverEditingID == nil && !isVideoCoverSaving && !containsRecordedMedia &&
            captionPolicy != nil && (captionRules == .current || captionRules == .extended) &&
            captionInput.formattedText.isEditable
    }
    @discardableResult
    public func requestCaptionCustomEmojiInsertion(descriptor: TelegramCustomEmojiDescriptor,
        catalog: TelegramCustomEmojiCatalogController, catalogContextID: UUID, expectedInput: TelegramComposerInput,
        contextID: UUID, revision: UUID, preparationID: UUID) -> Bool {
        guard canInsertCaptionCustomEmoji, let target, self.preparationID == preparationID,
              token == contextID, captionRevision == revision, captionInput == expectedInput,
              catalog.contextID == catalogContextID, catalog.snapshot?.accountID == target.accountID,
              catalog.canInsert(descriptor, chatID: target.chatID),
              (try? TelegramCustomEmojiInsertion.applying(descriptor, to: expectedInput)) != nil else { return false }
        let request = TelegramCustomEmojiInsertionRequest(descriptor: descriptor,
            expectedInput: expectedInput, contextID: contextID)
        pendingCaptionEmojiInsertion = .init(request: request, catalog: catalog, catalogContextID: catalogContextID,
            preparationID: preparationID, captionRevision: revision, itemsRevision: itemsRevision,
            target: target, bindingID: bindingID)
        captionCustomEmojiInsertion = request
        return true
    }
    @discardableResult
    public func consumeCaptionCustomEmojiInsertion(id: UUID, expectedInput: TelegramComposerInput) -> Bool {
        guard let pending = pendingCaptionEmojiInsertion, pending.request.id == id,
              captionCustomEmojiInsertion == pending.request else { return false }
        pendingCaptionEmojiInsertion = nil; captionCustomEmojiInsertion = nil
        return canInsertCaptionCustomEmoji && bindingID == pending.bindingID &&
            preparationID == pending.preparationID && target == pending.target &&
            captionRevision == pending.captionRevision && itemsRevision == pending.itemsRevision &&
            token == pending.request.contextID && expectedInput == captionInput &&
            expectedInput == pending.request.expectedInput &&
            pending.catalog.contextID == pending.catalogContextID &&
            pending.catalog.snapshot?.accountID == pending.target.accountID &&
            pending.catalog.canInsert(pending.request.descriptor, chatID: pending.target.chatID)
    }
    @Published public private(set) var mediaSpoiler = false
    @discardableResult
    public func updateMediaSpoiler(_ spoiler: Bool, contextID: UUID, revision: UUID) -> Bool {
        guard appendOperationID == nil, token == contextID, captionRevision == revision, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving,
              canUseMediaOptions else { return false }
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
        guard appendOperationID == nil, token == contextID, captionRevision == revision, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving,
              canUseMediaOptions else { return false }
        if captionAboveMedia != above {
            captionAboveMedia = above; captionRevision = UUID(); persistCaption()
        }
        return true
    }
    public var caption: String {
        get { captionInput.formattedText.text }
        set {
            guard appendOperationID == nil, videoCoverEditingID == nil, !isVideoCoverSaving else { return }
            guard !containsRecordedMedia || newValue.isEmpty else { return }
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
    private let submissionTimeout: Duration
    private var token = UUID()
    private var preparationID: UUID?
    private var committed = false
    private var sentCaption = TelegramComposerInput.empty.formattedText
    var didQueue: ((TelegramUploadTarget, TelegramFormattedText) -> Void)?
    var willSubmit: ((TelegramUploadTarget, TelegramFormattedText) -> Void)?
    var didPrepare: ((TelegramUploadTarget, TelegramComposerInput, UUID) -> Void)?
    var didFinishPreparation: ((UUID) -> Void)?
    // Per-instance deterministic staging seam, with identical ownership semantics.
    var stage: ((URL, TelegramUploadMode) async throws -> TelegramUploadFile)?
    var discard: (TelegramUploadFile) throws -> Void = TelegramUploadFileIO.discard
    // Instance-bound scheduling seam; the real immutable-input validation always follows.
    var willValidateUpload: (@Sendable () throws -> Void)?

    public init() { submissionTimeout = .seconds(30) }

    init(submissionTimeout: Duration) { self.submissionTimeout = submissionTimeout }

    @discardableResult
    func prepareRecordedRoundVideo(bytes: Data, target: TelegramUploadTarget, isOneTime: Bool = false) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 128 * 1024 * 1024,
              preparation == nil, phase == .idle || phase == .cancelled || phase == .failed || phase == .rejected,
              provider is any TelegramUploadBatchProvider, provider?.accountID == target.accountID,
              target.hasValidReplySource else { return false }
        clear(); resetCancellationPresentation()
        guard items.isEmpty, recoveredArchive == nil else { phase = .failed; return false }
        usesBatchRecovery = true; preparingRecordedRoundVideo = true; presentation = .media
        self.target = target; captionInput = .empty; phase = .preparing
        let request = token, bound = bindingID, discard = self.discard, store = recoveryStore
        preparationID = request; didPrepare?(target, .empty, request)
        guard token == request, phase == .preparing else { return false }
        let original = originalDraftForRecovery?(target, request)
        preparation = Task { [weak self] in
            do {
                let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes, isOneTime: isOneTime)
                guard let self else { try? discard(file); return }
                guard self.token == request, !Task.isCancelled else {
                    do { try discard(file) }
                    catch { if self.bindingID == bound { self.error = "Не удалось удалить временный файл." } }
                    self.preparation = nil
                    return
                }
                let staged = [TelegramUploadBatchItem(id: file.id, file: file)]
                self.preparation = nil; self.items = staged; self.selectedItemID = file.id
                self.preparingRecordedRoundVideo = false
                self.itemsRevision = UUID(); self.phase = .ready
                self.persistInitial(file: file, target: target, input: .empty, original: original,
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
              target.hasValidReplySource else { return false }
        clear(); resetCancellationPresentation()
        guard items.isEmpty, recoveredArchive == nil else { phase = .failed; return false }
        usesBatchRecovery = true; preparingRecordedVoice = true; presentation = .file
        self.target = target; captionInput = .empty; phase = .preparing
        let request = token, bound = bindingID, discard = self.discard, store = recoveryStore
        preparationID = request; didPrepare?(target, .empty, request)
        guard token == request, phase == .preparing else { return false }
        let original = originalDraftForRecovery?(target, request)
        preparation = Task { [weak self] in
            do {
                let file = try await TelegramRecordedVoiceIO.prepare(samples: samples, isOneTime: isOneTime)
                guard let self else { try? discard(file); return }
                guard self.token == request, !Task.isCancelled else {
                    do { try discard(file) }
                    catch { if self.bindingID == bound { self.error = "Не удалось удалить временный файл." } }
                    self.preparation = nil
                    return
                }
                let staged = [TelegramUploadBatchItem(id: file.id, file: file)]
                self.preparation = nil; self.items = staged; self.selectedItemID = file.id
                self.preparingRecordedVoice = false
                self.itemsRevision = UUID(); self.phase = .ready
                // Voice always needs a complete typed batch receipt. A missing
                // store blocks admission, including in local-only chat policy.
                self.persistInitial(file: file, target: target, input: .empty, original: original,
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
    public var captionMaximumUTF16Count: Int { captionPolicy?.maximumUTF16Count ?? 1024 }
    public var captionValidationUTF16Count: Int { captionRules.validationUTF16Count(captionInput.formattedText) }
    public var usesCaptionPlaceholder: Bool {
        TelegramUploadCaptionRules.usesCaptionPlaceholder(items: items, presentation: presentation, isGrouped: isGrouped, captionPolicy: captionPolicy)
    }
    public var canSend: Bool { phase == .ready && videoCoverEditingID == nil && !isVideoCoverSaving && !isRecoveryBusy && ((!usesBatchRecovery && !requiresRecovery && recoveryStore == nil) || recoveryPrepared) && provider?.accountID == target?.accountID && captionRules.canSend(captionInput.formattedText, maximumUTF16Count: captionMaximumUTF16Count) }
    public var canCancel: Bool { phase == .preparing || phase == .ready || phase == .storing }
    public var captionContextID: UUID { token }
    public var preparationContextID: UUID? { preparationID }
    public var showsPreparationPreview: Bool {
        guard preparationID != nil, !containsRecordedMedia else { return false }
        switch phase {
        case .preparing, .ready, .storing, .enqueuing, .uncertain: return true
        default: return false
        }
    }
    public var isRecordedVoice: Bool { containsRecordedVoice }
    public var isOneTimeVoice: Bool { file?.metadata?.voice?.isOneTime == true }

    public func send(contextID: UUID) {
        guard preparationID == contextID else { return }
        send()
    }

    public func sendAsSpoiler(contextID: UUID, revision: UUID) {
        guard preparationID == contextID, captionRevision == revision,
              canUseMediaOptions, canSend else { return }
        send(spoilerOverride: true)
    }

    public func dismissPreparation(contextID: UUID) {
        guard preparationID == contextID else { return }
        if canCancel { cancelPreparation(); clear() }
        else if phase == .uncertain { clear() }
    }

    @discardableResult
    public func updateCaptionInput(_ input: TelegramComposerInput, contextID: UUID) -> Bool {
        guard appendOperationID == nil, token == contextID, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving else { return false }
        guard !containsRecordedMedia || input == .empty else { return false }
        if captionInput != input {
            captionInput = input; captionRevision = UUID()
            if captionRules == .current, captionPolicy != nil, TelegramUploadCaptionRules.containsCustomEmoji(input.formattedText) {
                captionRules = .extended
            }
        }
        error = nil; persistCaption(); return true
    }

    func bind(provider: (any TelegramUploadProvider)?, recoveryStore: (any TelegramUploadRecoveryStore)? = nil, requiresRecovery: Bool = false) {
        // Rebinding detaches observation, preserving durable recovery state.
        resetObservation()
        bindingID = UUID()
        resetCancellationPresentation()
        self.provider = provider; self.recoveryStore = recoveryStore; self.requiresRecovery = requiresRecovery
    }

    public func prepare(source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, caption: String,
                        photoSize: TelegramUploadPhotoSize = .standard) {
        guard let input = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: caption)) else {
            error = "Не удалось подготовить подпись."; return
        }
        prepare(source: source, mode: mode, target: target, captionInput: input, photoSize: photoSize)
    }

    public func prepare(source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, captionInput: TelegramComposerInput,
                        photoSize: TelegramUploadPhotoSize = .standard) {
        guard preparation == nil, phase == .idle || phase == .cancelled || phase == .failed || phase == .rejected,
              provider?.accountID == target.accountID, target.hasValidReplySource else { return }
        clear()
        resetCancellationPresentation()
        guard file == nil, recoveredArchive == nil else { phase = .failed; return }
        self.target = target; self.captionInput = captionInput; phase = .preparing
        let request = token, discard = self.discard
        let stage = self.stage ?? { source, mode in try await TelegramUploadFileIO.stage(source, mode: mode, photoSize: photoSize) }
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
        guard captionRules.canSend(captionInput.formattedText, maximumUTF16Count: captionMaximumUTF16Count) else {
            error = "Подпись или её форматирование не поддерживаются. Максимум — \(captionMaximumUTF16Count) знака UTF16."; return
        }
        guard canSend, let provider, let file, let target else { return }
        videoPlayback.stop()
        let frozen = captionInput, frozenAbove = captionAboveMedia, frozenSpoiler = spoilerOverride ?? mediaSpoiler
        let bundle = usesBatchRecovery ? TelegramRecoveredUploadBundle(items: items, archive: recoveredArchive) : nil
        let grouped = isGrouped, presentation = self.presentation, descriptor = archiveDescriptor, rules = captionRules, frozenPolicy = captionPolicy, frozenMediaRules = mediaRules
        if let store = recoveryStore, let id = preparationID {
            let bound = bindingID
            isRecoveryBusy = true; recoveryRetry = nil
            phase = .storing
            Task { [weak self] in
                guard self?.bindingID == bound, self?.preparationID == id, self?.phase == .storing else { return }
                do {
                    try await store.save(preparationID: id, chatID: target.chatID, captionInput: frozen, captionAboveMedia: frozenAbove, mediaSpoiler: frozenSpoiler, disposition: .submissionStarted)
                    if let bundle {
                        guard let batchProvider = provider as? any TelegramUploadBatchProvider,
                              let draft = try await store.load(chatID: target.chatID), draft.isValid,
                              (6...19).contains(draft.resourceSchemaVersion), draft.archive == descriptor, draft.captionRules == rules, draft.captionPolicy == frozenPolicy, draft.mediaRules == frozenMediaRules,
                              draft.id == id, draft.disposition == .submissionStarted,
                              draft.items.map(\.id) == bundle.items.map(\.id), draft.isGrouped == grouped, draft.presentation == presentation,
                              draft.items.map(\.sourceFacts) == bundle.items.map(\.sourceFacts),
                              draft.captionInput == frozen, draft.captionAboveMedia == frozenAbove, draft.mediaSpoiler == frozenSpoiler else {
                            throw TelegramPendingUploadPersistenceError.conflict
                        }
                        guard let self, self.bindingID == bound, self.preparationID == id, self.phase == .storing else { return }
                        self.isRecoveryBusy = false
                        self.dispatchBatch(provider: batchProvider, store: store, bundle: bundle, draft: draft, target: target)
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
                               bundle: TelegramRecoveredUploadBundle, draft: TelegramPendingUploadDraft, target: TelegramUploadTarget) {
        let request = UUID(); token = request; committed = false; messageID = nil; messageIDs = []; acceptancePending = false
        sentInput = draft.captionInput; sentCaption = draft.captionInput.formattedText
        sentCaptionAboveMedia = draft.captionAboveMedia; sentMediaSpoiler = draft.mediaSpoiler
        phase = .storing; error = nil
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
                // String equality merges canonical Unicode spellings; the ZIP
                // descriptor must preserve its exact encoded member names.
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard let accepted = try await store.load(chatID: draft.chatID), accepted.id == draft.id,
                      accepted.resourceSchemaVersion == draft.resourceSchemaVersion, accepted.accountID == draft.accountID, accepted.chatID == draft.chatID,
                      accepted.title == draft.title, accepted.items == draft.items, accepted.isGrouped == draft.isGrouped,
                      try encoder.encode(accepted.archive) == encoder.encode(draft.archive),
                      accepted.presentation == draft.presentation, accepted.captionRules == draft.captionRules,
                      accepted.captionPolicy == draft.captionPolicy, accepted.mediaRules == draft.mediaRules,
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
        startSubmissionDeadline(request: request)
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
        preparingRecordedVoice = false; preparingRecordedRoundVideo = false
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
        pendingCaptionEmojiInsertion = nil; captionCustomEmojiInsertion = nil
        if appendOperationID != nil { preparation?.cancel(); preparation = nil; appendOperationID = nil }
        sourceURLsByItemID = [:]
        recoveryRestoreEpoch = UUID()
        videoCoverEditingID = nil; videoCoverWriteRevision = nil; videoCoverRevision = UUID()
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
                write.input = captionInput; write.above = captionAboveMedia; write.spoiler = mediaSpoiler
                presentationWrites[id] = write
                if !detachedRecoveryWrites.contains(id) {
                    let frozen = write
                    presentationWrites.removeValue(forKey: id)
                    detachedRecoveryRetries[id] = { [weak self] in self?.writePresentation(frozen) }
                }
            } else if !detachedRecoveryWrites.contains(id) { finishPresentationWrite(id) }
            updateDetachedRecoveryStatus()
        } else if recoveryInitialInFlight, let id = preparationID, cancelledRecoveryContents[id] == nil {
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
        usesBatchRecovery = false; captionRules = .legacy; captionPolicy = nil; mediaRules = .legacy; preparingRecordedVoice = false; preparingRecordedRoundVideo = false
        isGrouped = false; presentation = .media; itemsRevision = UUID()
        captionAboveMedia = false; mediaSpoiler = false; captionRevision = UUID()
        phase = .idle; acceptancePending = false; recoveryPrepared = false
        recoveryRetry = nil; isRecoveryBusy = false; recoveryStatus = nil
        let notice = "Отправка могла остаться в очереди Telegram. Повторно автоматически не отправляем."
        error = !cleaned ? "Не удалось удалить временный файл." + (possiblyQueued ? " " + notice : "") : possiblyQueued ? notice : nil
        finishPreparation()
    }

    private func startSubmissionDeadline(request: UUID) {
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
        case .awaitingApproval:
            guard (phase == .storing || phase == .enqueuing), messageID == nil, !acceptancePending else { return }
            // The provider has not entered the native enqueue transaction yet.
            // User confirmation has no network deadline and remains cancellable.
            committed = false; phase = .storing
            deadline?.cancel(); deadline = nil
        case .committing:
            guard phase == .storing else { return }
            committed = true; phase = .enqueuing
            startSubmissionDeadline(request: token)
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
                                batchItems: [TelegramUploadBatchItem]? = nil, grouped: Bool = false, frozenPolicy: TelegramUploadCaptionPolicy? = nil) {
        guard let store, store.accountID == target.accountID else {
            recoveryPrepared = false; recoveryStatus = "Настройте хранилище вложений для сохранения перед отправкой."
            recoveryRetry = nil
            return
        }
        isRecoveryBusy = true; recoveryInitialInFlight = true; recoveryRetry = nil
        let discard = self.discard, cancellationPresentation = cancellationPresentationID, batchPresentation = presentation
        let staged = batchItems ?? [.init(id: file.id, file: file)]
        let policy = frozenPolicy ?? captionPolicy
        Task { [weak self] in
            do {
                if let batchItems {
                    try await store.prepare(preparationID: id, items: batchItems, isGrouped: grouped, presentation: batchPresentation, target: target,
                        captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, originalDraft: original, captionPolicy: policy)
                } else {
                    try await store.prepare(preparationID: id, file: file, target: target, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, originalDraft: original)
                }
                var boundPolicy: TelegramUploadCaptionPolicy?
                if let policy {
                    guard let saved = try await store.load(chatID: target.chatID), saved.isValid, saved.id == id,
                          saved.accountID == target.accountID, saved.chatID == target.chatID,
                          saved.captionRules == (TelegramUploadCaptionRules.containsCustomEmoji(input.formattedText) ? .extended : .current), saved.items.map(\.id) == staged.map(\.id),
                          saved.captionPolicy == (try policy.binding(staged)) else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                    boundPolicy = saved.captionPolicy
                }
                if let cancelled = self?.cancelledRecoveryContents.removeValue(forKey: id) {
                    self?.persistCancellation(store: store, id: id, chatID: target.chatID, input: cancelled.input, bound: bound, above: cancelled.above, spoiler: cancelled.spoiler, presentation: cancellationPresentation)
                }
                self?.persistDetachedInitialIfNeeded(store: store, id: id, chatID: target.chatID)
                guard let self, self.bindingID == bound, self.preparationID == id else { for item in staged { try? item.discard(using: discard) }; return }
                self.captionPolicy = boundPolicy
                self.recoveryInitialInFlight = false; self.isRecoveryBusy = false; self.recoveryPrepared = true; self.recoveryStatus = nil
                if self.captionInput != input || self.captionAboveMedia != above || self.mediaSpoiler != spoiler { self.persistCaption() }
            } catch {
                if let cancelled = self?.cancelledRecoveryContents.removeValue(forKey: id) {
                    self?.persistCancellation(store: store, id: id, chatID: target.chatID, input: cancelled.input, bound: bound, above: cancelled.above, spoiler: cancelled.spoiler, presentation: cancellationPresentation)
                }
                self?.persistDetachedInitialIfNeeded(store: store, id: id, chatID: target.chatID)
                guard let self, self.bindingID == bound, self.preparationID == id else { for item in staged { try? item.discard(using: discard) }; return }
                self.recoveryInitialInFlight = false; self.isRecoveryBusy = false; self.recoveryPrepared = false
                self.recoveryStatus = "Не удалось сохранить вложение. Отправка заблокирована."
                self.recoveryRetry = { [weak self] in self?.persistInitial(file: file, target: target, input: input, original: original, id: id, bound: bound, store: store, above: above, spoiler: spoiler, batchItems: batchItems, grouped: grouped, frozenPolicy: policy) }
            }
        }
    }
    private func persistCaption() {
        guard appendOperationID == nil, let store = recoveryStore, recoveryPrepared, let id = preparationID, let target, phase == .ready else { return }
        let bound = bindingID, input = captionInput, above = captionAboveMedia, spoiler = mediaSpoiler, coverRevision = videoCoverRevision, itemRevision = itemsRevision
        Task { [weak self] in
            guard self?.appendOperationID == nil, self?.bindingID == bound, self?.preparationID == id, self?.phase == .ready, self?.itemsRevision == itemRevision, self?.captionInput == input, self?.captionAboveMedia == above, self?.mediaSpoiler == spoiler else { return }
            do {
                try await store.save(preparationID: id, chatID: target.chatID, captionInput: input, captionAboveMedia: above, mediaSpoiler: spoiler, disposition: .prepared)
                if self?.captionRules == .extended {
                    guard let saved = try await store.load(chatID: target.chatID), saved.isValid,
                          saved.id == id, saved.accountID == target.accountID, saved.chatID == target.chatID,
                          saved.threadID == target.selectedThreadID, saved.captionRules == .extended,
                          saved.captionInput == input, saved.captionAboveMedia == above, saved.mediaSpoiler == spoiler else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                }
                guard let self, self.appendOperationID == nil, self.bindingID == bound, self.preparationID == id, self.itemsRevision == itemRevision, self.videoCoverRevision == coverRevision, self.captionInput == input, self.captionAboveMedia == above, self.mediaSpoiler == spoiler, self.phase == .ready else { return }
                self.recoveryStatus = nil; self.recoveryRetry = nil
            } catch {
                guard let self, self.appendOperationID == nil, self.bindingID == bound, self.preparationID == id, self.itemsRevision == itemRevision, self.videoCoverRevision == coverRevision, self.captionInput == input, self.captionAboveMedia == above, self.mediaSpoiler == spoiler, self.phase == .ready else { return }
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
    func restore(draft: TelegramPendingUploadDraft, bundle: TelegramRecoveredUploadBundle, target: TelegramUploadTarget, restorationEpoch: UUID,
                 admission: @MainActor () -> Bool = { true }) async -> Bool {
        guard draft.isValid else { return false }
        let items = bundle.items
        if draft.resourceSchemaVersion < 6 {
            guard bundle.archive == nil, items.count == 1, items[0].id == draft.items[0].id else { return false }
            return await restore(draft: draft, file: items[0].file, target: target, restorationEpoch: restorationEpoch, admission: admission)
        }
        guard restorationEpoch == recoveryRestoreEpoch, phase == .idle, self.items.isEmpty, recoveredArchive == nil,
              (6...19).contains(draft.resourceSchemaVersion),
              provider is any TelegramUploadBatchProvider, provider?.accountID == draft.accountID,
              recoveryStore?.accountID == draft.accountID, target.accountID == draft.accountID, target.chatID == draft.chatID,
              target.selectedThreadID == draft.threadID,
              target.hasValidReplySource, detachedInitialContents[draft.id] == nil,
              !detachedRecoveryWrites.contains(draft.id), detachedRecoveryRetries[draft.id] == nil,
              admission() else { return false }
        let bound = bindingID, request = token, revision = itemsRevision, validate = willValidateUpload
        let valid = try? await BackgroundWork.run {
            try validate?()
            return Self.matchesItems(items, draft: draft) && (draft.archive != nil
                ? Self.matchesArchive(bundle.archive, draft: draft)
                : !draft.hasArchiveSchema && bundle.archive == nil)
        }
        guard valid == true, !Task.isCancelled, admission(), bindingID == bound, token == request, itemsRevision == revision,
              restorationEpoch == recoveryRestoreEpoch, phase == .idle, self.items.isEmpty, recoveredArchive == nil,
              provider is any TelegramUploadBatchProvider, provider?.accountID == draft.accountID,
              recoveryStore?.accountID == draft.accountID, detachedInitialContents[draft.id] == nil,
              !detachedRecoveryWrites.contains(draft.id), detachedRecoveryRetries[draft.id] == nil else { return false }
        switch draft.disposition {
        case .prepared:
            guard draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else { return false }
        case .submissionStarted: break
        case .accepted, .acceptedBatch, .cancelled: return false
        }
        token = UUID(); preparationID = draft.id; self.items = items; selectedItemID = items[0].id
        recoveredArchive = bundle.archive; archiveDescriptor = draft.archive
        usesBatchRecovery = true; captionRules = draft.captionRules; captionPolicy = draft.captionPolicy; mediaRules = draft.mediaRules
        isGrouped = draft.isGrouped; presentation = draft.presentation; itemsRevision = UUID()
        self.target = target; captionInput = draft.captionInput; captionAboveMedia = draft.captionAboveMedia
        mediaSpoiler = draft.mediaSpoiler; captionRevision = UUID()
        sentInput = draft.captionInput; sentCaption = draft.captionInput.formattedText
        sentCaptionAboveMedia = draft.captionAboveMedia; sentMediaSpoiler = draft.mediaSpoiler
        recoveryPrepared = true; committed = draft.disposition == .submissionStarted
        phase = committed ? .uncertain : .ready
        didRestore?(target, draft.originalDraft, draft.id)
        return true
    }
    private nonisolated static func matchesItems(_ items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft) -> Bool {
        items.count == draft.items.count && zip(items, draft.items).allSatisfy({ staged, saved in
                  staged.id == saved.id && staged.file.name.utf8.elementsEqual(saved.file.attachment.name.utf8) &&
                  staged.file.size == saved.file.plaintextByteCount && staged.file.mode.rawValue == saved.file.attachment.kind &&
                  staged.file.video == saved.video && telegramPendingUploadCoverMatches(saved.videoCover, staged.file.videoCover) &&
                  staged.file.metadata == saved.metadata && staged.sourceFacts == saved.sourceFacts &&
                  saved.matchesOriginal(staged.originalFile) &&
                  (try? TelegramUploadFileIO.validateOwnedStage(staged.file)) != nil &&
                  (staged.file.videoCover == nil || (try? TelegramUploadVideoCoverIO.validatedBytes(staged.file.videoCover!)) != nil)
              })
    }
    private nonisolated static func matchesArchive(_ value: TelegramUploadArchiveIO.Archive?, draft: TelegramPendingUploadDraft) -> Bool {
            guard draft.hasArchiveSchema, let descriptor = draft.archive, let archive = value,
                  archive.file.name.utf8.elementsEqual(descriptor.file.attachment.name.utf8),
                  archive.file.size == descriptor.file.plaintextByteCount, archive.file.mode == .file,
                  archive.file.video == nil, archive.file.videoCover == nil, archive.file.metadata == nil,
                  archive.file.pixelWidth == nil, archive.file.pixelHeight == nil,
                  (try? TelegramUploadFileIO.validateOwnedStage(archive.file)) != nil,
                  archive.members.count == descriptor.members.count,
                  zip(archive.members, zip(descriptor.members, draft.items)).allSatisfy({ member, saved in
                      let raw = saved.1.originalFile ?? saved.1.file
                      return member.itemID == saved.0.itemID && member.itemID == saved.1.id &&
                          member.entryName.utf8.elementsEqual(saved.0.entryName.utf8) &&
                          member.sourceName.utf8.elementsEqual(raw.attachment.name.utf8) &&
                          member.byteCount == raw.plaintextByteCount && member.plaintextSHA256 == raw.plaintextSHA256
                  }) else { return false }
            return true
    }
    @discardableResult
    func restore(draft: TelegramPendingUploadDraft, items: [TelegramUploadBatchItem], target: TelegramUploadTarget, restorationEpoch: UUID) async -> Bool {
        guard draft.archive == nil else { return false }
        return await restore(draft: draft, bundle: .init(items: items, archive: nil), target: target, restorationEpoch: restorationEpoch)
    }
    @discardableResult
    func restore(draft: TelegramPendingUploadDraft, file: TelegramUploadFile, target: TelegramUploadTarget, restorationEpoch: UUID,
                 admission: @MainActor () -> Bool = { true }) async -> Bool {
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
              telegramPendingUploadCoverMatches(draft.videoCover, file.videoCover), admission() else { return false }
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
              detachedRecoveryRetries[draft.id] == nil else { return false }
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
    private nonisolated static func excludingRetainedCover(_ file: TelegramUploadFile, retained: Set<UUID>) -> TelegramUploadFile {
        guard let cover = file.videoCover, retained.contains(cover.id) else { return file }
        return TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: file.mode,
            pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: file.url, directory: file.directory,
            video: file.video, videoCover: nil, metadata: file.metadata)
    }
    @discardableResult private func cleanup() -> Bool {
        videoPlayback.stop()
        let retained = Set(videoCoverWrites.values.compactMap { $0.cover?.id })
        for write in videoCoverWrites.values { write.detached = true }
        let discard = self.discard
        var failed: [TelegramUploadBatchItem] = []
        for item in items + retiredItems {
            do { try item.discard(using: { try discard(Self.excludingRetainedCover($0, retained: retained)) }) }
            catch { failed.append(item) }
        }
        items = failed; retiredItems = []
        if let recoveredArchive {
            do { try discard(recoveredArchive.file); self.recoveredArchive = nil; archiveDescriptor = nil }
            catch { self.error = "Не удалось удалить временный файл." }
        }
        if !items.contains(where: { $0.id == selectedItemID }) { selectedItemID = items.first?.id }
        if !failed.isEmpty { self.error = "Не удалось удалить временный файл." }
        return failed.isEmpty && recoveredArchive == nil
    }
    isolated deinit {
        videoPlayback.stop(); preparation?.cancel(); deadline?.cancel(); lease?.stop()
        // Initial writes own their set; cover writes independently own their candidate.
        let retained = Set(videoCoverWrites.values.compactMap { $0.cover?.id })
        for write in videoCoverWrites.values { write.detached = true }
        if !recoveryInitialInFlight {
            for item in items + retiredItems {
                try? item.discard(using: { try discard(Self.excludingRetainedCover($0, retained: retained)) })
            }
        }
        if let recoveredArchive { try? discard(recoveredArchive.file) }
    }
}
