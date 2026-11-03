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
    public init(
        accountID: Int64, chatID: Int64, title: String, replySource: TelegramMessageActionSource? = nil, selectedThreadID: Int64? = nil
    ) {
        self.accountID = accountID
        self.chatID = chatID
        self.title = title
        self.replySource = replySource
        self.selectedThreadID = selectedThreadID
    }
    var hasValidReplySource: Bool {
        if let selectedThreadID { guard selectedThreadID > 0, selectedThreadID <= Int64(Int32.max) else { return false } }
        guard let source = replySource else { return true }
        if let selectedThreadID { guard source.peerID == chatID, source.threadID == selectedThreadID else { return false } }
        return source.accountID == accountID && source.chatID == chatID && source.canReply && !source.fingerprint.isEmpty
            && (source.peerID == chatID || source.metadata.migrationChatID == chatID)
    }
}
public enum TelegramUploadPhase: Equatable, Sendable {
    case idle, preparing, ready, storing, enqueuing, queued(Double?), queueFailed
    case rejected, uncertain, cancelled, failed
}
@MainActor protocol TelegramUploadLease: AnyObject { func stop() }
@MainActor protocol TelegramUploadProvider: AnyObject {
    var accountID: Int64 { get }
    func submit(
        file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
        captionAboveMedia: Bool, mediaSpoiler: Bool,
        receive: @escaping @MainActor (TelegramUploadEvent) -> Void
    ) -> any TelegramUploadLease
}
enum TelegramUploadEvent {
    case awaitingApproval, committing, accepted(String), progress(Double?), queueFailed, rejected, uncertain
}

@MainActor public final class TelegramUploadController: ObservableObject {
    @Published public internal(set) var items: [TelegramUploadBatchItem] = []
    @Published public internal(set) var itemsRevision = UUID()
    @Published public internal(set) var selectedItemID: UUID?
    @Published public internal(set) var isGrouped = false
    @Published public internal(set) var presentation: TelegramUploadPresentation = .media
    @Published public internal(set) var messageIDs: [String] = []
    var usesBatchRecovery = false
    var captionRules: TelegramUploadCaptionRules = .legacy
    var captionPolicy: TelegramUploadCaptionPolicy?
    var mediaRules: TelegramUploadMediaRules = .legacy
    var preparingRecordedVoice = false
    var preparingRecordedRoundVideo = false
    var retiredItems: [TelegramUploadBatchItem] = []
    var recoveredArchive: TelegramUploadArchiveIO.Archive?
    var archiveDescriptor: TelegramPendingUploadArchive?
    var presentationWrites: [UUID: PresentationWrite] = [:]
    var sourceURLsByItemID: [UUID: URL] = [:]
    var appendOperationID: UUID?
    @Published public internal(set) var videoCoverRevision = UUID()
    @Published public internal(set) var videoCoverEditingID: UUID?
    @Published var videoCoverWriteRevision: UUID?
    /// The write retains its candidate path until real capture/save completes,
    /// independently of the observed account or the controller's lifetime.
    @MainActor final class VideoCoverWrite {
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
        init(
            store: any TelegramUploadRecoveryStore, original: TelegramUploadFile, cover: TelegramUploadVideoCover?,
            target: TelegramUploadTarget, id: UUID, binding: UUID, revision: UUID, itemID: UUID?,
            input: TelegramComposerInput, above: Bool, spoiler: Bool
        ) {
            self.store = store
            self.original = original
            self.cover = cover
            self.target = target
            self.id = id
            self.binding = binding
            self.revision = revision
            self.itemID = itemID
            self.input = input
            self.above = above
            self.spoiler = spoiler
        }
        isolated deinit {
            if detached, let cover {
                Task.detached(priority: .utility) { try? TelegramUploadFileIO.discard(cover.imageFile) }
            }
        }
    }
    var videoCoverWrites: [UUID: VideoCoverWrite] = [:]
    public let videoPlayback = TelegramUploadVideoPlaybackController()
    @Published public internal(set) var phase: TelegramUploadPhase = .idle
    @Published public internal(set) var target: TelegramUploadTarget?
    @Published public internal(set) var captionInput: TelegramComposerInput = .empty
    @Published public internal(set) var captionCustomEmojiInsertion: TelegramCustomEmojiInsertionRequest?
    var pendingCaptionEmojiInsertion: CaptionEmojiInsertion?
    @Published public internal(set) var mediaSpoiler = false
    @Published public internal(set) var captionAboveMedia = false
    @Published public internal(set) var captionRevision = UUID()
    @Published public internal(set) var messageID: String?
    @Published public internal(set) var error: String?
    @Published public internal(set) var recoveryStatus: String?
    @Published public internal(set) var isRecoveryBusy = false
    public var canRetryRecovery: Bool { recoveryRetry != nil && !isRecoveryBusy }
    @Published public internal(set) var cancellationStatus: String?
    @Published public internal(set) var isCancellationBusy = false
    public var canRetryCancellation: Bool { cancellationRetry != nil && !isCancellationBusy }
    public func retryCancellation() {
        guard !isCancellationBusy else { return }
        cancellationRetry?()
    }
    var cancellationRetry: (() -> Void)?
    var cancellationPresentationID = UUID()
    var cancellationStarted: Set<UUID> = []
    var recoveryRetry: (() -> Void)?
    var recoveryStore: (any TelegramUploadRecoveryStore)?
    var requiresRecovery = false
    var recoveryPrepared = false
    var recoveryInitialInFlight = false
    var bindingID = UUID()
    var recoveryRestoreEpoch = UUID()
    var acceptancePending = false
    var cancelledRecoveryContents: [UUID: (input: TelegramComposerInput, above: Bool, spoiler: Bool)] = [:]
    var sentCaptionAboveMedia = false
    var sentMediaSpoiler = false
    @Published public internal(set) var detachedRecoveryStatus: String?
    public var canRetryDetachedRecovery: Bool { !detachedRecoveryRetries.isEmpty }
    public func retryDetachedRecovery() { for retry in Array(detachedRecoveryRetries.values) { retry() } }
    var detachedInitialContents: [UUID: (input: TelegramComposerInput, above: Bool, spoiler: Bool)] = [:]
    var detachedRecoveryWrites: Set<UUID> = []
    var detachedRecoveryRetries: [UUID: () -> Void] = [:]
    var sentInput: TelegramComposerInput = .empty
    var originalDraftForRecovery: ((TelegramUploadTarget, UUID) -> TelegramComposerDraft?)?
    var didRestore: ((TelegramUploadTarget, TelegramComposerDraft?, UUID) -> Void)?
    var provider: (any TelegramUploadProvider)?
    var lease: (any TelegramUploadLease)?
    var preparation: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    let submissionTimeout: Duration
    var token = UUID()
    var preparationID: UUID?
    var committed = false
    var sentCaption = TelegramComposerInput.empty.formattedText
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

    public var captionMaximumUTF16Count: Int { captionPolicy?.maximumUTF16Count ?? 1024 }
    public var captionValidationUTF16Count: Int { captionRules.validationUTF16Count(captionInput.formattedText) }
    public var usesCaptionPlaceholder: Bool {
        TelegramUploadCaptionRules.usesCaptionPlaceholder(
            items: items, presentation: presentation, isGrouped: isGrouped, captionPolicy: captionPolicy)
    }
    public var canSend: Bool {
        phase == .ready && videoCoverEditingID == nil && !isVideoCoverSaving && !isRecoveryBusy
            && ((!usesBatchRecovery && !requiresRecovery && recoveryStore == nil) || recoveryPrepared)
            && provider?.accountID == target?.accountID
            && captionRules.canSend(captionInput.formattedText, maximumUTF16Count: captionMaximumUTF16Count)
    }
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

    func bind(
        provider: (any TelegramUploadProvider)?, recoveryStore: (any TelegramUploadRecoveryStore)? = nil, requiresRecovery: Bool = false
    ) {
        // Rebinding detaches observation, preserving durable recovery state.
        resetObservation()
        bindingID = UUID()
        resetCancellationPresentation()
        self.provider = provider
        self.recoveryStore = recoveryStore
        self.requiresRecovery = requiresRecovery
    }

    isolated deinit {
        videoPlayback.stop()
        preparation?.cancel()
        deadline?.cancel()
        lease?.stop()
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
