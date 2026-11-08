import Foundation
import MakoshBuildConfiguration
import Combine
import MakoshCore
import Security
import TelegramCore
import Postbox
import SwiftSignalKit
import AVFoundation

@MainActor
public final class TelegramModel: ObservableObject {
    public let notifications = TelegramNotificationController()
    public let customEmojiCatalog = TelegramCustomEmojiCatalogController()
    @Published public internal(set) var customEmojiPlaybackContext: TelegramCustomEmojiPlaybackContext?
    @Published public internal(set) var customEmojiDescriptors: [Int64: TelegramCustomEmojiDescriptor] = [:]
    @Published public internal(set) var customEmojiInsertion: TelegramCustomEmojiInsertionRequest?
    var pendingEmojiInsertion:
        (
            request: TelegramCustomEmojiInsertionRequest, account: Int64,
            chat: Int64, thread: Int64?, revision: UUID?, catalog: UUID
        )?
    let emojiResolution = MetaDisposable(), capabilityObservation = MetaDisposable()
    var emojiResolutionID = UUID(), emojiRequested = Set<Int64>()
    var emojiCatalogObservation: AnyCancellable?
    var emojiForumObservation: AnyCancellable?
    var emojiUploadObservation: AnyCancellable?

    @Published public internal(set) var replyQuoteMaximumUTF16Count = 1024
    let replyQuoteLimitObservation = MetaDisposable()
    public let sendApproval = TelegramSendApprovalController()
    public let calls: TelegramCallController
    var callSelectionAccount: Int64?, callSelectionPeer: Int64?
    public let secretChats = TelegramSecretChatController()
    var secretObservation: AnyCancellable?
    var callControlObservation: AnyCancellable?
    @Published public internal(set) var conversationCapabilities: TelegramConversationCapabilities? { didSet { refreshCallSelection() } }
    public let forumTopics = TelegramForumTopicsController()
    @Published public var isForumTopicsListPresented = true
    @Published public internal(set) var selectedThreadID: Int64?
    public let search = TelegramSearchModel()
    public let globalSearch = TelegramSearchModel(global: true)
    public let sharedMedia = TelegramSearchModel()
    public let peerManagement = TelegramPeerManagementController()
    public let accountSessions = TelegramSessionsController()
    public let webSessions = TelegramWebSessionsController()
    public let appearanceCatalog = TelegramAppearanceCatalogController()
    public let qrLogin = TelegramQRLoginController()
    var qrMigrationCount = 0
    public let accountPrivacy = TelegramPrivacyController()
    public let accountBlockedUsers = TelegramBlockedUsersController()
    /// The contacts of the ready account for the Persons section; one provider per account session.
    var contactsProviderValue: (any TelegramContactsProvider)?
    public let accountTwoStep = TelegramTwoStepController()
    public let media = TelegramMediaController()
    var backgroundDownloads: TelegramEngineDownloadJournal?
    public let autoDownloadSettings: TelegramAutoDownloadSettings
    public let cache = TelegramCacheController()
    public let cacheMaintenance: TelegramCacheMaintenance
    /// Whether the local session reconnects at launch (`connectIfRemembered`).
    let autoConnect: MakoshAutoConnect
    public let proxy: TelegramProxyController
    var proxyClientID = UUID()
    lazy var automaticDownloads = TelegramAutoDownloadQueue(settings: autoDownloadSettings, media: media)
    var automaticArchiveObservation: AnyCancellable?
    @Published public internal(set) var automaticDownloadsPaused = false
    public let avatars = TelegramAvatarStore()
    public let peerStatus = TelegramPeerStatusController()
    public let profilePhotos = TelegramProfilePhotosController()
    public let avatarEditing = TelegramAvatarEditingController()
    public let groupMembership = TelegramGroupMembershipController()
    public let groupMemberSearch = TelegramRemotePeerSearch()
    public let playback = TelegramPlaybackController()
    public let upload = TelegramUploadController()
    public let voiceRecording = TelegramVoiceRecordingController()
    let recordingPermissions = TelegramRecordingPermissionRequest()
    let voiceEligibilityRequest = TelegramVoiceEligibilityRequest()
    var voicePreparationID: UUID?
    @Published public internal(set) var voiceInputContextID = UUID()
    public let archive = TelegramArchiveController()
    public let messageActions = TelegramMessageActionsController()
    public let composerReply = TelegramComposerReplyController()
    public let composerForward = TelegramComposerForwardController()
    public let messageSelection = TelegramMessageSelectionController()
    public let selectedMessagesCopy = TelegramSelectedMessagesCopyController()
    public let selectedMessagesDelete = TelegramSelectedMessagesDeleteController()
    public let savedMessagesForward = TelegramSavedMessagesForwardController()
    var savedForwardSelection: (requestID: UUID, selection: TelegramMessageSelectionSession?)?
    var selectedDeleteEditSession: TelegramMessageEditSession?
    var selectionRangeProvider: (any TelegramMessageSelectionRangeProvider)?
    let selectionRangeDisposable = MetaDisposable()
    var selectionRangeDeadline: Task<Void, Never>?
    @Published public internal(set) var composerForwardIntent: TelegramComposerForwardIntent?
    @Published public internal(set) var composerForwardDisposition: TelegramComposerForwardDisposition?
    @Published public internal(set) var isRestoringComposerDraft = false
    @Published public internal(set) var composerDraftRecoveryError: String?
    @Published public internal(set) var serverDraftConflict: TelegramServerDraftConflict?
    @Published public internal(set) var isResolvingServerDraft = false
    var serverDraftObserver: (any TelegramServerDraftObserving)?
    let serverDraftObservation = MetaDisposable(), serverDraftResolution = MetaDisposable()
    var serverDraftContext: TelegramServerDraftObservationContext?
    var serverDraftResolutionID: UUID?
    var serverDraftResolutionDeadline: Task<Void, Never>?
    var nextServerDraftUpdate: TelegramServerDraftUpdate?
    var pendingForwardStage:
        (context: UUID, destination: Int64, intent: TelegramComposerForwardIntent, origin: (chat: Int64, thread: Int64?, intent: UUID)?)?
    public var uploadContextID: UUID { conversationGeneration }
    public var messageActionContextID: UUID { conversationGeneration }
    public var contactProfileContextID: UUID { conversationGeneration }
    @Published public internal(set) var contactProfileState: TelegramContactProfileState = .idle
    var contactProfileRequestID: UUID?
    @Published public internal(set) var phase: TelegramPhase = .configuration
    @Published public internal(set) var isBusy = false
    @Published public var error: String?
    @Published public internal(set) var chats: [TelegramChat] = []
    @Published public internal(set) var messages: [TelegramMessage] = []
    @Published public internal(set) var chatPage: TelegramPageNavigation = .idle
    @Published public internal(set) var historyPage: TelegramPageNavigation = .idle
    @Published public var chatFolder: TelegramChatFolder = .inbox {
        didSet {
            if oldValue != chatFolder {
                loadChatList(clear: true)
                search.setFolder(chatFolder)
            }
        }
    }
    @Published public internal(set) var workspaceFolders: [TelegramWorkspaceFolder] = []
    @Published public internal(set) var workspaceFolderID: Int32? = nil
    var workspaceNativeFolders: [ChatListFilter] = []
    let workspaceFolderObservation = MetaDisposable()

    let historyRead = TelegramHistoryReadController()
    var historyReadIndexes: [String: MessageIndex] = [:]
    #if DEBUG
    @Published public internal(set) var syntheticHistoryReadCount = 0
    @Published public internal(set) var syntheticHistoryReadLastMessage: Int32?
    @Published public internal(set) var syntheticHistoryReadWindowActive = false
    #endif
    @Published public internal(set) var historyFocusID: String?
    @Published public var selectedChatID: Int64? {
        didSet {
            guard oldValue != selectedChatID else { return }
            pendingEmojiInsertion = nil
            customEmojiInsertion = nil
            sendApproval.cancel()
            if selectedThreadID != nil {
                conversationGeneration = UUID()
                selectedThreadID = nil
            }
            forumTopics.selectChat(selectedChatID)
            cancelVoiceRecording()
            cancelMessageSelectionRange()
            selectedMessagesCopy.cancel()
            messageSelection.cancel()
            cancelContactProfile()
            playback.stop()
            if let id = selectedChatID, let found = search.chats.first(where: { $0.id == id }) { knownChats[id] = found }
            if let accountID = draftAccountID {
                displayComposerInput(
                    selectedChatID.flatMap { drafts.snapshot(accountID: accountID, chatID: $0, threadID: selectedThreadID)?.input }
                        ?? .empty)
            } else {
                displayComposerInput(.empty)
            }
            projectMessageEditSession()
            refreshComposerReply()
            refreshComposerForward()
            pendingRecoveryAttempt = nil
            cancelPendingRecovery()
            restoreComposerDraft()
            restorePendingUpload()
            refreshServerDraftObservation()
            search.selectChat(selectedChatID)
            peerStatus.selectPeer(selectedChatID)
            refreshConversationFilePolicy()
            refreshConversationCapabilities()
            loadHistory()
        }
    }
    @Published public internal(set) var composerInput: TelegramComposerInput = .empty
    @Published public internal(set) var uploadCaptionMaximumUTF16Count = 1024
    @Published public internal(set) var codeExplanation = "Введите код, полученный от Telegram."
    @Published public internal(set) var connectionDescription = "Не подключено"
    public internal(set) var isSyntheticPreview = false
    var configuration: TelegramAPIConfiguration?
    var manager: AccountManager<TelegramAccountManagerTypes>?
    var unauthorized: UnauthorizedAccount?
    var challenge: TelegramAuthorizationChallenge = .phoneCode
    var account: Account?
    var generation = UUID()
    var accountGeneration = UUID()
    var conversationGeneration = UUID()
    var authorizationGeneration = UUID()
    var drafts = TelegramDraftStore()
    @Published var unsavedComposerDrafts: [ComposerDraftKey: TelegramComposerDraft] = [:]
    let composerPersistenceError =
        "Не удалось сохранить черновик на диске. Текст и выбранный ответ остаются в памяти; повторите сохранение перед выходом."
    var composerDraftRepository: (any TelegramComposerDraftRepository)?
    var composerDraftGeneration = UUID()
    var composerDraftLoadID: UUID?
    let composerDraftLoad = MetaDisposable()
    var replyComposerSubmission: (source: TelegramMessageActionSource, draft: TelegramComposerDraft)?
    var uploadComposerSubmission: (draft: TelegramComposerDraft, caption: TelegramFormattedText)?
    var uploadComposerPreparationID: UUID?
    var uploadComposerTransfer: (id: UUID, draft: TelegramComposerDraft)?
    @Published public internal(set) var isRestoringPendingUpload = false
    @Published public internal(set) var pendingUploadRecoveryError: String?
    #if DEBUG
    var syntheticPendingPostbox: Postbox?
    #endif
    var pendingRecoveryStore: (any TelegramUploadRecoveryStore)?
    var pendingReplyProvider: (any TelegramComposerReplyProvider)?
    var pendingRecoveryTask: Task<Void, Never>?
    var pendingRecoveryDeadline: Task<Void, Never>?
    var pendingRecoveryID = UUID()
    var pendingRecoveryAttempt: (account: Int64, chat: Int64)?

    struct EditDraftKey: Hashable {
        let account: Int64, peer: Int64, namespace: Int32, message: Int32
        let chat: Int64, thread: Int64?
        let fingerprint: Data
        init(_ source: TelegramMessageActionSource) {
            account = source.accountID
            peer = source.peerID
            namespace = source.namespace
            message = source.messageID
            chat = source.chatID
            thread = source.threadID
            fingerprint = Data(source.fingerprint.utf8)
        }
    }
    @Published public internal(set) var messageEditSession: TelegramMessageEditSession?
    var messageEditSessions: [Int64: TelegramMessageEditSession] = [:]
    var submittedEditSession: TelegramMessageEditSession?
    var editDrafts: [EditDraftKey: TelegramFormattedText] = [:]
    var knownChats: [Int64: TelegramChat] = [:]
    var mediaProvider: TelegramEngineMediaProvider?
    var historyMediaSources: [TelegramAttachmentSource] = []
    var chatPages = TelegramPageTracker<ChatListIndex>()
    var historyPages = TelegramPageTracker<MessageIndex>()
    let sessionWorker = TelegramSessionWorker()
    var sessionOpeningTask: Task<Void, Never>?
    var openingTimeout: Task<Void, Never>?
    var chatPageTimeout: Task<Void, Never>?
    var historyPageTimeout: Task<Void, Never>?
    var contactProfileTimeout: Task<Void, Never>?
    #if DEBUG
    var preview: TelegramSyntheticPages?
    var extendedMessagesPreview = false
    var peerProfilesPreview = false
    var secretChatsPreview = false
    var callsPreviewProvider: TelegramSyntheticCallProvider?
    var syntheticAccountID: Int64 = -1
    #endif
    var draftAccountID: Int64? {
        #if DEBUG
        if isSyntheticPreview { return syntheticAccountID }
        #endif
        return account?.peerId.toInt64()
    }
    func refreshConversationFilePolicy() {
        archive.files.policy.select(accountID: draftAccountID, chatID: selectedChatID)
    }
    let session = MetaDisposable()
    let authState = MetaDisposable()
    let action = MetaDisposable()
    let chatList = MetaDisposable()
    let history = MetaDisposable()
    let connection = MetaDisposable()
    let outgoing = MetaDisposable()
    let uploadCaptionLimit = MetaDisposable()
    let contactProfileSubscription = MetaDisposable()

    public init(proxy: TelegramProxyController? = nil, calls: TelegramCallController? = nil, autoDownloadDefaults: UserDefaults = .standard)
    {
        self.calls = calls ?? TelegramCallController()
        autoDownloadSettings = TelegramAutoDownloadSettings(defaults: autoDownloadDefaults)
        cacheMaintenance = TelegramCacheMaintenance(defaults: autoDownloadDefaults)
        autoConnect = MakoshAutoConnect(scope: "telegram", defaults: autoDownloadDefaults)
        self.proxy = proxy ?? TelegramProxyController()
        callControlObservation = self.calls.$call.combineLatest(self.calls.$isReleasingMedia, self.calls.$captureReserved).sink {
            [weak self] _, _, _ in self?.objectWillChange.send()
        }
        self.calls.permitsStart = { [weak self] in self?.voiceRecording.isActive == false }
        secretObservation = secretChats.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        secretChats.didCreate = { [weak self] session, context in
            guard let self, self.phase == .ready, self.draftAccountID == session.accountID,
                self.selectedChatID == session.regularPeerID, self.secretChats.creationContextID == context
            else { return }
            let chat = TelegramChat(id: session.chatID, title: session.title, preview: "Секретный чат", unreadCount: 0)
            self.knownChats[chat.id] = chat
            if !self.chats.contains(where: { $0.id == chat.id }) { self.chats.insert(chat, at: 0) }
            self.selectedChatID = chat.id
        }
        automaticArchiveObservation = archive.files.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.automaticDownloads.archiveCapacityChanged()
                self?.media.archiveCapacityChanged()
            }
        }
        cache.permitsClear = { [weak self] in
            guard let self else { return false }
            return self.permitsCloudCacheRemoval && !self.cacheMaintenance.isRunning
        }
        cacheMaintenance.permitsClear = { [weak self] in
            guard let self else { return false }
            return self.permitsCloudCacheRemoval && self.cache.phase == .idle
        }
        notifications.didActivate = { [weak self] event in self?.activateNotification(event) == true }
        emojiCatalogObservation = customEmojiCatalog.$snapshot.sink { [weak self] snapshot in
            let items =
                (snapshot?.recent ?? []) + (snapshot?.installed.flatMap(\.items) ?? []) + (snapshot?.featured.flatMap(\.items) ?? [])
            self?.refreshCustomEmojiDescriptors(catalogItems: items)
        }
        emojiForumObservation = forumTopics.$snapshot.sink { [weak self] snapshot in
            self?.refreshCustomEmojiDescriptors(topics: snapshot?.topics ?? [])
        }
        emojiUploadObservation = upload.$captionInput.sink { [weak self] input in
            // Published emits before storage changes. Resolve the emitted input,
            // including restores/removal, rather than the preceding caption.
            self?.refreshCustomEmojiDescriptors(uploadCaption: input.formattedText)
        }
        voiceRecording.didCancel = { [weak self] in self?.cancelVoicePreparation() }
        voiceRecording.isCurrent = { [weak self] target, context in self?.isCurrentVoice(target, context: context) == true }
        voiceRecording.authorize = { [weak self] in
            await self?.authorizeRecording(kind: .voice) == true
        }
        voiceRecording.makeCapture = { [weak self] in
            #if DEBUG
            if self?.isSyntheticPreview == true { return TelegramSyntheticVoiceCapture() }
            #endif
            return try TelegramMicrophoneVoiceCapture()
        }
        voiceRecording.eligibility = { [weak self] target in await self?.checkVoiceEligibility(target) ?? .unavailable }
        voiceRecording.oneTimeEligibility = { [weak self] target in await self?.checkVoiceEligibility(target, isOneTime: true) == .allowed }
        voiceRecording.handoff = { [weak self] samples, target, context, send, once in
            await self?.prepareVoiceRecording(samples: samples, target: target, context: context, send: send, isOneTime: once) == true
        }
        voiceRecording.authorizeRoundVideo = { [weak self] in await self?.authorizeRecording(kind: .roundVideo) == true }
        voiceRecording.makeRoundVideoCapture = { [weak self] in
            #if DEBUG
            if self?.isSyntheticPreview == true { return try TelegramSyntheticRoundVideoCapture() }
            #endif
            return try TelegramCameraRoundVideoCapture()
        }
        voiceRecording.roundVideoEligibility = { [weak self] target in
            await self?.checkVoiceEligibility(target, kind: .roundVideo) ?? .unavailable
        }
        voiceRecording.roundVideoOneTimeEligibility = { [weak self] target in
            await self?.checkVoiceEligibility(target, isOneTime: true, kind: .roundVideo) == .allowed
        }
        voiceRecording.roundVideoHandoff = { [weak self] bytes, target, context, send, once in
            await self?.prepareRoundVideoRecording(bytes: bytes, target: target, context: context, send: send, isOneTime: once) == true
        }
        search.mediaSourcesDidChange = { [weak self] in self?.refreshMediaSources() }
        globalSearch.mediaSourcesDidChange = { [weak self] in self?.refreshMediaSources() }
        sharedMedia.mediaSourcesDidChange = { [weak self] in self?.refreshMediaSources() }
        search.selectionDidChange = { [weak self] id, context in
            guard let self, self.search.resultContextID == context,
                let index = self.search.messageIndex(id: id, inChat: self.selectedChatID, threadID: self.selectedThreadID)
            else { return }
            self.loadHistory(anchor: index, clear: false, focusID: id)
        }
        globalSearch.selectionDidChange = { [weak self] id, context in self?.activateGlobalSearchResult(id: id, contextID: context) }
        search.dateDidSelect = { [weak self] index, id, context in
            guard let self, self.search.resultContextID == context else { return }
            self.loadHistory(anchor: index, clear: false, focusID: id)
        }
        upload.originalDraftForRecovery = { [weak self] _, id in
            guard let transfer = self?.uploadComposerTransfer, transfer.id == id else { return nil }
            return transfer.draft
        }
        upload.didRestore = { [weak self] target, original, id in
            guard let self else { return }
            self.uploadComposerPreparationID = id
            self.uploadComposerTransfer = nil
            if let original, original.accountID == target.accountID, original.chatID == target.chatID,
                self.drafts.snapshot(accountID: original.accountID, chatID: original.chatID, threadID: original.threadID)?.revision
                    == original.revision
            {
                self.uploadComposerTransfer = (id, original)
                if self.selectedChatID == target.chatID {
                    self.displayComposerInput(.empty)
                    self.refreshComposerReply()
                }
            }
        }
        upload.didPrepare = { [weak self] target, input, id in self?.suspendUploadComposer(target: target, input: input, id: id) }
        upload.didFinishPreparation = { [weak self] id in self?.finishUploadComposer(id: id) }
        upload.willSubmit = { [weak self] target, caption in self?.captureUploadDraft(target: target, caption: caption) }
        upload.didQueue = { [weak self] target, caption in self?.acknowledgeUpload(target: target, caption: caption) }
        messageActions.didQueue = { [weak self] action, source in
            guard let self, source.accountID == self.draftAccountID, let formatted = self.replyText(action),
                let submitted = self.replyComposerSubmission, submitted.source == source
            else { return }
            self.replyComposerSubmission = nil
            self.acknowledgeComposerDraft(formatted: formatted, submitted: submitted.draft)
        }
        savedMessagesForward.didChange = { [weak self] in self?.objectWillChange.send() }
        savedMessagesForward.didRecoverAcceptance = { [weak self] request in
            // Recovery is guarded by the current provider binding, not the old
            // operation's context. Durable acceptance already removed this forward.
            guard let self, self.draftAccountID == request.accountID, let origin = request.origin,
                let current = self.drafts.snapshot(accountID: request.accountID, chatID: origin.chatID),
                current.revision == origin.revision, current.forwardIntent?.id == origin.intentID,
                current.forwardIntent?.sources == request.sources,
                self.drafts.setForwardIntent(nil, accountID: request.accountID, chatID: origin.chatID) != nil
            else { return }
            if self.savedForwardSelection?.requestID == request.id { self.savedForwardSelection = nil }
            if self.selectedChatID == origin.chatID { self.refreshComposerForward() }
        }
        savedMessagesForward.didQueue = { [weak self] request in
            guard let self, self.conversationGeneration == request.contextID, self.draftAccountID == request.accountID,
                let captured = self.savedForwardSelection, captured.requestID == request.id
            else { return }
            self.savedForwardSelection = nil
            if let origin = request.origin,
                let current = self.drafts.snapshot(accountID: request.accountID, chatID: origin.chatID),
                current.revision == origin.revision, current.forwardIntent?.id == origin.intentID,
                let cleared = self.drafts.setForwardIntent(nil, accountID: request.accountID, chatID: origin.chatID)
            {
                self.persistComposerDraft(cleared)
                if self.selectedChatID == origin.chatID { self.refreshComposerForward() }
            }
            if let selected = captured.selection, let current = self.messageSelection.session,
                current.id == selected.id, current.revision == selected.revision, current.contextID == selected.contextID,
                current.accountID == selected.accountID, current.chatID == selected.chatID
            {
                self.cancelMessageSelectionRange()
                self.selectedMessagesCopy.cancel()
                self.messageSelection.cancel()
            }
        }
        selectedMessagesDelete.didQueue = { [weak self] request in
            guard let self, self.conversationGeneration == request.contextID, self.draftAccountID == request.accountID else { return }
            if let captured = self.selectedDeleteEditSession,
                self.messageEditSessions[request.chatID] == captured,
                request.sources.contains(where: { $0 == captured.source })
            {
                self.messageEditSessions[request.chatID] = nil
                self.editDrafts[EditDraftKey(captured.source)] = nil
                self.projectMessageEditSession()
            }
            self.selectedDeleteEditSession = nil
            if let current = self.messageSelection.session, current.id == request.sessionID,
                current.revision == request.revision, current.contextID == request.contextID,
                current.accountID == request.accountID, current.chatID == request.chatID
            {
                self.cancelMessageSelectionRange()
                self.messageSelection.cancel()
            }
        }
        messageActions.didApply = { [weak self] action, source in
            guard let self, source.accountID == self.draftAccountID else { return }
            let submitted: TelegramFormattedText?
            switch action {
            case let .edit(text): submitted = try? TelegramFormattedText(text: text)
            case let .editFormatted(value, _): submitted = value
            default: return
            }
            let captured = self.submittedEditSession
            self.submittedEditSession = nil
            if let captured, captured.source == source, captured.contextID == self.conversationGeneration,
                self.messageEditSessions[source.chatID] == captured
            {
                self.messageEditSessions[source.chatID] = nil
                self.projectMessageEditSession()
            }
            let key = EditDraftKey(source)
            if captured == nil || self.messageEditSessions[source.chatID] == nil {
                if let submitted, self.editDrafts[key] == submitted { self.editDrafts[key] = nil }
            }
        }
        composerForward.didUpdateDraft = { [weak self] captured, replacement in
            guard let self, captured.accountID == self.draftAccountID,
                let current = self.drafts.snapshot(accountID: captured.accountID, chatID: captured.chatID, threadID: captured.threadID),
                current.revision == captured.revision, current.input == captured.input,
                current.replyTarget == captured.replyTarget, current.forwardIntent == captured.forwardIntent,
                self.drafts.restore(
                    replacement, accountID: captured.accountID, chatID: captured.chatID, threadID: captured.threadID,
                    expectedRevision: current.revision)
            else { return }
            let key = ComposerDraftKey(accountID: captured.accountID, chatID: captured.chatID, threadID: captured.threadID)
            if self.unsavedComposerDrafts[key]?.revision == captured.revision { self.unsavedComposerDrafts[key] = nil }
            // Provider transitions have already committed to the captured Postbox.
            if self.selectedChatID == captured.chatID, self.selectedThreadID == captured.threadID {
                self.displayComposerInput(replacement.input)
                self.refreshComposerReply()
                self.refreshComposerForward()
            }
        }
    }

    isolated deinit {
        unauthorized?.shouldBeServiceTaskMaster.set(.single(.never))
        proxy.unregister(clientID: proxyClientID)
        notifications.bind(accountID: nil)
        emojiResolution.dispose()
        capabilityObservation.dispose()
        customEmojiPlaybackContext?.invalidate()
        serverDraftResolutionDeadline?.cancel()
        selectionRangeDeadline?.cancel()
        selectionRangeDisposable.dispose()
        playback.stop()
        sessionOpeningTask?.cancel()
        openingTimeout?.cancel()
        chatPageTimeout?.cancel()
        historyPageTimeout?.cancel()
        contactProfileTimeout?.cancel()
        pendingRecoveryTask?.cancel()
        pendingRecoveryDeadline?.cancel()
        account?.shouldBeServiceTaskMaster.set(.single(.never))
        account?.shouldKeepOnlinePresence.set(.single(false))
        account?.network.shouldKeepConnection.set(.single(false))
        for disposable in [
            workspaceFolderObservation, session, authState, action, chatList, history, connection, outgoing, uploadCaptionLimit,
            contactProfileSubscription, composerDraftLoad, serverDraftObservation, serverDraftResolution,
        ] { disposable.dispose() }
    }

}
