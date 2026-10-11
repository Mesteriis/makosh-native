import Foundation
import MakoshCore
import Combine
import Security
import TelegramCore
import Postbox
import SwiftSignalKit
import OpenSSLEncryption

public enum TelegramPhase: Equatable {
    case configuration, connecting, phone, code, password(hint: String), ready, unsupported(String)
}

public struct TelegramChat: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let preview: String
    public let unreadCount: Int
    public var presence: TelegramChatPresence? = nil
}

public struct TelegramMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let text: String
    public let author: String
    public let isOutgoing: Bool
    public let delivery: TelegramMessageDelivery
    public var attachments: [TelegramAttachment] = []
    public var actionMetadata: TelegramMessageActionMetadata? = nil
    public var albumGroupID: UInt32? = nil
    public var nativeGroupingKey: Int64? = nil
    public var canGroupMedia = true
    /// Received placement for supported photo/video; an album caption may belong to another member.
    public var captionAboveMedia = false
    public var formattedTextForDisplay: TelegramFormattedText? {
        guard let metadata = actionMetadata else { return try? TelegramFormattedText(text: text) }
        guard let value = metadata.formattedText, value.text.utf8.elementsEqual(text.utf8) else { return nil }
        return value
    }
}

public struct TelegramAPIConfiguration: Equatable {
    public let id: Int32
    public let hash: String
    public init(id: String, hash: String) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHash = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsed = Int32(trimmedID), parsed > 0,
              trimmedHash.utf8.count == 32,
              trimmedHash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw TelegramSetupError.invalidAPI
        }
        self.id = parsed
        self.hash = trimmedHash
    }
}

enum TelegramSetupError: LocalizedError {
    case invalidAPI, keychain, missingSessionKey, filesystem
    var errorDescription: String? {
        switch self {
        case .invalidAPI: "Укажите положительный API ID и API hash из 32 шестнадцатеричных символов, полученные для вашего приложения."
        case .keychain: "Не удалось открыть ключ сеанса в Связке ключей. Данные сеанса не изменены."
        case .missingSessionKey: "Ключ существующего сеанса недоступен. Восстановите Связку ключей; Макош не создаёт новый ключ поверх старых данных."
        case .filesystem: "Не удалось открыть отдельный каталог сеанса Макоша. Проверьте доступ к Application Support."
        }
    }
}

/// Own integration over the exact TelegramSwift engine gitlink. Initialization
/// performs no account, Keychain, filesystem or network access until Connect.
@MainActor
public final class TelegramModel: ObservableObject {
    public let search = TelegramSearchModel()
    public let media = TelegramMediaController()
    public let avatars = TelegramAvatarStore()
    public let peerStatus = TelegramPeerStatusController()
    public let profilePhotos = TelegramProfilePhotosController()
    public let playback = TelegramPlaybackController()
    public let upload = TelegramUploadController()
    public let archive = TelegramArchiveController()
    public let messageActions = TelegramMessageActionsController()
    public let composerReply = TelegramComposerReplyController()
    public let composerForward = TelegramComposerForwardController()
    public let messageSelection = TelegramMessageSelectionController()
    public let selectedMessagesCopy = TelegramSelectedMessagesCopyController()
    public let selectedMessagesDelete = TelegramSelectedMessagesDeleteController()
    public let savedMessagesForward = TelegramSavedMessagesForwardController()
    private var savedForwardSelection: (requestID: UUID, selection: TelegramMessageSelectionSession?)?
    public var selectedMessagesDeletionBlocksActions: Bool { selectedMessagesDelete.isBusy || selectedMessagesDelete.phase == .uncertain }
    private var selectedDeleteEditSession: TelegramMessageEditSession?
    private var selectionRangeProvider: (any TelegramMessageSelectionRangeProvider)?
    private let selectionRangeDisposable = MetaDisposable()
    private var selectionRangeDeadline: Task<Void, Never>?
    @Published public private(set) var composerForwardIntent: TelegramComposerForwardIntent?
    @Published public private(set) var composerForwardDisposition: TelegramComposerForwardDisposition?
    @Published public private(set) var isRestoringComposerDraft = false
    @Published public private(set) var composerDraftRecoveryError: String?
    private var pendingForwardStage: (context: UUID, destination: Int64, intent: TelegramComposerForwardIntent, origin: (chat: Int64, intent: UUID)?)?
    public var uploadContextID: UUID { accountGeneration }
    public var messageActionContextID: UUID { accountGeneration }
    public var contactProfileContextID: UUID { accountGeneration }
    @Published public private(set) var contactProfileState: TelegramContactProfileState = .idle
    var contactProfileRequestID: UUID?
    public var forwardDestinations: [TelegramChat] {
        var destinations = knownChats
        for chat in search.chats { destinations[chat.id] = chat }
        return destinations.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public var savedMessagesChatID: Int64? { phase == .ready ? draftAccountID : nil }
    public var messageActionForwardDestinations: [TelegramChat] {
        guard let id = savedMessagesChatID else { return forwardDestinations }
        return [TelegramChat(id: id, title: "Избранное", preview: "", unreadCount: 0)] + forwardDestinations.filter { $0.id != id }
    }
    @Published public private(set) var phase: TelegramPhase = .configuration
    @Published public private(set) var isBusy = false
    @Published public var error: String?
    @Published public private(set) var chats: [TelegramChat] = []
    @Published public private(set) var messages: [TelegramMessage] = []
    public var historyItems: [TelegramHistoryItem] {
        guard let accountID = draftAccountID, let chatID = selectedChatID else { return [] }
        return TelegramHistoryItem.project(messages, accountID: accountID, chatID: chatID)
    }
    @Published public private(set) var chatPage: TelegramPageNavigation = .idle
    @Published public private(set) var historyPage: TelegramPageNavigation = .idle
    @Published public var chatFolder: TelegramChatFolder = .inbox {
        didSet { if oldValue != chatFolder { loadChatList(clear: true); search.setFolder(chatFolder) } }
    }
    public var selectedChat: TelegramChat? { selectedChatID.flatMap { knownChats[$0] } }
    public var uploadTarget: TelegramUploadTarget? {
        guard phase == .ready, !isBusy, !selectedMessagesDeletionBlocksActions, composerDraftRecoveryError == nil,
              composerForwardIntent == nil, let chat = selectedChat, let accountID = draftAccountID else { return nil }
        if !isSyntheticPreview {
            guard [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel]
                .contains(PeerId(chat.id).namespace) else { return nil }
        }
        return TelegramUploadTarget(accountID: accountID, chatID: chat.id, title: chat.title)
    }
    public var historyWindowID: UUID? { historyPages.requestID }
    public var historyReadContext: TelegramHistoryReadContext? {
        guard phase == .ready, !search.hasMessageQuery, !historyPage.isLoading, !historyPage.timedOut,
              let accountID = draftAccountID, let chatID = selectedChatID,
              let windowID = historyWindowID else { return nil }
        return TelegramHistoryReadContext(accountID: accountID, chatID: chatID,
            accountContextID: accountGeneration, historyWindowID: windowID)
    }
    let historyRead = TelegramHistoryReadController()
    var historyReadIndexes: [String: MessageIndex] = [:]
    #if DEBUG
    @Published public internal(set) var syntheticHistoryReadCount = 0
    @Published public internal(set) var syntheticHistoryReadLastMessage: Int32?
    @Published public internal(set) var syntheticHistoryReadWindowActive = false
    #endif
    @Published public private(set) var historyFocusID: String?
    public var readyHistoryFocusID: String? {
        guard !historyPage.isLoading, !historyPage.timedOut,
              let id = historyFocusID, messages.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    var chatWindowID: UUID? { chatPages.requestID }
    @Published public var selectedChatID: Int64? {
        didSet {
            guard oldValue != selectedChatID else { return }
            cancelMessageSelectionRange()
            selectedMessagesCopy.cancel()
            messageSelection.cancel()
            cancelContactProfile()
            playback.stop()
            if let id = selectedChatID, let found = search.chats.first(where: { $0.id == id }) { knownChats[id] = found }
            if let accountID = draftAccountID {
                displayComposerInput(selectedChatID.flatMap { drafts.snapshot(accountID: accountID, chatID: $0)?.input } ?? .empty)
            } else { displayComposerInput(.empty) }
            projectMessageEditSession()
            refreshComposerReply()
            refreshComposerForward()
            pendingRecoveryAttempt = nil
            cancelPendingRecovery()
            restoreComposerDraft()
            restorePendingUpload()
            search.selectChat(selectedChatID)
            peerStatus.selectPeer(selectedChatID)
            loadHistory()
        }
    }
    @Published public private(set) var composerInput: TelegramComposerInput = .empty
    /// Compatibility for plain input callers. Native rich input updates the
    /// complete value atomically, including its UTF16 selection.
    public var draft: String {
        get { composerInput.formattedText.text }
        set {
            if newValue.utf8.elementsEqual(draft.utf8) { setComposerInput(composerInput); return }
            guard let value = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: newValue)) else {
                error = "Не удалось сохранить текст ввода."; return
            }
            setComposerInput(value)
        }
    }
    public var composerCanSend: Bool {
        guard messageSelection.session == nil, !isRestoringPendingUpload, !isRestoringComposerDraft, composerDraftRecoveryError == nil, pendingUploadRecoveryError == nil else { return false }
        if composerForwardIntent != nil {
            guard !isForwardComposerLocked, composerForward.phase == .ready,
                  composerInput.formattedText.text.isEmpty || telegramFormattedTextCanSend(composerInput.formattedText),
                  let accountID = draftAccountID, let chatID = selectedChatID else { return false }
            return (isSyntheticPreview && composerDraftRepository == nil) || unsavedComposerDrafts[ComposerDraftKey(accountID: accountID, chatID: chatID)] == nil
        }
        return telegramFormattedTextCanSend(composerInput.formattedText)
    }
    public var composerSupportsAttachments: Bool { composerInput.formattedText.isEditable && composerForwardIntent == nil }
    public var isForwardComposerLocked: Bool {
        guard let intent = composerForwardIntent else { return false }
        let saved = savedMessagesForward.request
        let recoveringSaved = saved == nil && (savedMessagesForward.isBusy || savedMessagesForward.phase == .uncertain)
        let retargetingSaved = saved?.accountID == draftAccountID && saved?.origin?.chatID == selectedChatID &&
            saved?.origin?.intentID == intent.id && (savedMessagesForward.isBusy || savedMessagesForward.phase == .uncertain)
        return recoveringSaved || retargetingSaved || composerForwardDisposition != .prepared ||
            composerForward.phase == .committing || composerForward.phase == .uncertain
    }
    public var composerForwardRevision: UUID? {
        guard let accountID = draftAccountID, let chatID = selectedChatID, composerForwardIntent != nil else { return nil }
        return drafts.snapshot(accountID: accountID, chatID: chatID)?.revision
    }
    @Published public private(set) var codeExplanation = "Введите код, полученный от Telegram."
    @Published public private(set) var connectionDescription = "Не подключено"
    public private(set) var isSyntheticPreview = false
    private var configuration: TelegramAPIConfiguration?
    private var manager: AccountManager<TelegramAccountManagerTypes>?
    private var unauthorized: UnauthorizedAccount?
    private var challenge: TelegramAuthorizationChallenge = .phoneCode
    private var account: Account?
    private var generation = UUID()
    private var accountGeneration = UUID()
    private var authorizationGeneration = UUID()
    private var drafts = TelegramDraftStore()
    private struct ComposerDraftKey: Hashable { let accountID: Int64; let chatID: Int64 }
    @Published private var unsavedComposerDrafts: [ComposerDraftKey: TelegramComposerDraft] = [:]
    private let composerPersistenceError = "Не удалось сохранить черновик на диске. Текст и выбранный ответ остаются в памяти; повторите сохранение перед выходом."
    public var canRetryComposerDraftPersistence: Bool {
        guard let accountID = draftAccountID, composerDraftRepository?.accountID == accountID else { return false }
        return unsavedComposerDrafts.values.contains { $0.accountID == accountID }
    }
    private var composerDraftRepository: (any TelegramComposerDraftRepository)?
    private var composerDraftGeneration = UUID()
    private var composerDraftLoadID: UUID?
    private let composerDraftLoad = MetaDisposable()
    private var replyComposerSubmission: (source: TelegramMessageActionSource, draft: TelegramComposerDraft)?
    private var uploadComposerSubmission: (draft: TelegramComposerDraft, caption: TelegramFormattedText)?
    private var uploadComposerPreparationID: UUID?
    private var uploadComposerTransfer: (id: UUID, draft: TelegramComposerDraft)?
    public var isComposerSuspended: Bool {
        guard let transfer = uploadComposerTransfer, transfer.draft.accountID == draftAccountID,
              transfer.draft.chatID == selectedChatID else { return false }
        return drafts.snapshot(accountID: transfer.draft.accountID, chatID: transfer.draft.chatID)?.revision == transfer.draft.revision
    }
    @Published public private(set) var isRestoringPendingUpload = false
    @Published public private(set) var pendingUploadRecoveryError: String?
    #if DEBUG
    var syntheticPendingPostbox: Postbox?
    #endif
    private var pendingRecoveryStore: (any TelegramUploadRecoveryStore)?
    private var pendingReplyProvider: (any TelegramComposerReplyProvider)?
    private var pendingRecoveryTask: Task<Void, Never>?
    private var pendingRecoveryDeadline: Task<Void, Never>?
    private var pendingRecoveryID = UUID()
    private var pendingRecoveryAttempt: (account: Int64, chat: Int64)?

    private struct EditDraftKey: Hashable {
        let account: Int64, peer: Int64, namespace: Int32, message: Int32
        let chat: Int64, thread: Int64?
        let fingerprint: Data
        init(_ source: TelegramMessageActionSource) {
            account = source.accountID; peer = source.peerID; namespace = source.namespace; message = source.messageID
            chat = source.chatID; thread = source.threadID; fingerprint = Data(source.fingerprint.utf8)
        }
    }
    @Published public private(set) var messageEditSession: TelegramMessageEditSession?
    private var messageEditSessions: [Int64: TelegramMessageEditSession] = [:]
    private var submittedEditSession: TelegramMessageEditSession?
    private var editDrafts: [EditDraftKey: TelegramFormattedText] = [:]
    private var knownChats: [Int64: TelegramChat] = [:]
    private var mediaProvider: TelegramEngineMediaProvider?
    private var historyMediaSources: [TelegramAttachmentSource] = []
    private var chatPages = TelegramPageTracker<ChatListIndex>()
    private var historyPages = TelegramPageTracker<MessageIndex>()
    private var openingTimeout: Task<Void, Never>?
    private var chatPageTimeout: Task<Void, Never>?
    private var historyPageTimeout: Task<Void, Never>?
    private var contactProfileTimeout: Task<Void, Never>?
    #if DEBUG
    private var preview: TelegramSyntheticPages?
    private var peerProfilesPreview = false
    #endif
    private var draftAccountID: Int64? {
        if isSyntheticPreview { return -1 }
        return account?.peerId.toInt64()
    }
    private let session = MetaDisposable()
    private let authState = MetaDisposable()
    private let action = MetaDisposable()
    private let chatList = MetaDisposable()
    private let history = MetaDisposable()
    private let connection = MetaDisposable()
    private let outgoing = MetaDisposable()
    private let contactProfileSubscription = MetaDisposable()

    public init() {
        search.mediaSourcesDidChange = { [weak self] in self?.refreshMediaSources() }
        upload.originalDraftForRecovery = { [weak self] _, id in
            guard let transfer = self?.uploadComposerTransfer, transfer.id == id else { return nil }
            return transfer.draft
        }
        upload.didRestore = { [weak self] target, original, id in
            guard let self else { return }
            self.uploadComposerPreparationID = id
            self.uploadComposerTransfer = nil
            if let original, original.accountID == target.accountID, original.chatID == target.chatID,
               self.drafts.snapshot(accountID: original.accountID, chatID: original.chatID)?.revision == original.revision {
                self.uploadComposerTransfer = (id, original)
                if self.selectedChatID == target.chatID { self.displayComposerInput(.empty); self.refreshComposerReply() }
            }
        }
        upload.didPrepare = { [weak self] target, input, id in self?.suspendUploadComposer(target: target, input: input, id: id) }
        upload.didFinishPreparation = { [weak self] id in self?.finishUploadComposer(id: id) }
        upload.willSubmit = { [weak self] target, caption in self?.captureUploadDraft(target: target, caption: caption) }
        upload.didQueue = { [weak self] target, caption in self?.acknowledgeUpload(target: target, caption: caption) }
        messageActions.didQueue = { [weak self] action, source in
            guard let self, source.accountID == self.draftAccountID, let formatted = self.replyText(action),
                  let submitted = self.replyComposerSubmission, submitted.source == source else { return }
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
                  self.drafts.setForwardIntent(nil, accountID: request.accountID, chatID: origin.chatID) != nil else { return }
            if self.savedForwardSelection?.requestID == request.id { self.savedForwardSelection = nil }
            if self.selectedChatID == origin.chatID { self.refreshComposerForward() }
        }
        savedMessagesForward.didQueue = { [weak self] request in
            guard let self, self.accountGeneration == request.contextID, self.draftAccountID == request.accountID,
                  let captured = self.savedForwardSelection, captured.requestID == request.id else { return }
            self.savedForwardSelection = nil
            if let origin = request.origin,
               let current = self.drafts.snapshot(accountID: request.accountID, chatID: origin.chatID),
               current.revision == origin.revision, current.forwardIntent?.id == origin.intentID,
               let cleared = self.drafts.setForwardIntent(nil, accountID: request.accountID, chatID: origin.chatID) {
                self.persistComposerDraft(cleared)
                if self.selectedChatID == origin.chatID { self.refreshComposerForward() }
            }
            if let selected = captured.selection, let current = self.messageSelection.session,
               current.id == selected.id, current.revision == selected.revision, current.contextID == selected.contextID,
               current.accountID == selected.accountID, current.chatID == selected.chatID {
                self.cancelMessageSelectionRange(); self.selectedMessagesCopy.cancel(); self.messageSelection.cancel()
            }
        }
        selectedMessagesDelete.didQueue = { [weak self] request in
            guard let self, self.accountGeneration == request.contextID, self.draftAccountID == request.accountID else { return }
            if let captured = self.selectedDeleteEditSession,
               self.messageEditSessions[request.chatID] == captured,
               request.sources.contains(where: { $0 == captured.source }) {
                self.messageEditSessions[request.chatID] = nil
                self.editDrafts[EditDraftKey(captured.source)] = nil
                self.projectMessageEditSession()
            }
            self.selectedDeleteEditSession = nil
            if let current = self.messageSelection.session, current.id == request.sessionID,
               current.revision == request.revision, current.contextID == request.contextID,
               current.accountID == request.accountID, current.chatID == request.chatID {
                self.cancelMessageSelectionRange()
                self.messageSelection.cancel()
            }
        }
        messageActions.didApply = { [weak self] action, source in
            guard let self, source.accountID == self.draftAccountID else { return }
            let submitted: TelegramFormattedText?
            switch action {
            case let .edit(text): submitted = try? TelegramFormattedText(text: text)
            case let .editFormatted(value): submitted = value
            default: return
            }
            let captured = self.submittedEditSession
            self.submittedEditSession = nil
            if let captured, captured.source == source, captured.contextID == self.accountGeneration,
               self.messageEditSessions[source.chatID] == captured {
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
                  let current = self.drafts.snapshot(accountID: captured.accountID, chatID: captured.chatID),
                  current.revision == captured.revision, current.input == captured.input,
                  current.replyTarget == captured.replyTarget, current.forwardIntent == captured.forwardIntent,
                  self.drafts.restore(replacement, accountID: captured.accountID, chatID: captured.chatID,
                      expectedRevision: current.revision) else { return }
            let key = ComposerDraftKey(accountID: captured.accountID, chatID: captured.chatID)
            if self.unsavedComposerDrafts[key]?.revision == captured.revision { self.unsavedComposerDrafts[key] = nil }
            // Provider transitions have already committed to the captured Postbox.
            if self.selectedChatID == captured.chatID {
                self.displayComposerInput(replacement.input); self.refreshComposerReply(); self.refreshComposerForward()
            }
        }
    }

    private func displayComposerInput(_ input: TelegramComposerInput) {
        composerInput = isComposerSuspended ? .empty : input
    }

    private func setComposerInput(_ input: TelegramComposerInput) {
        guard !isForwardComposerLocked else { return }
        composerInput = input
        guard let accountID = draftAccountID, let chatID = selectedChatID else { return }
        if let changed = drafts.save(input: input, accountID: accountID, chatID: chatID) { persistComposerDraft(changed) }
        refreshComposerForward()
    }

    @discardableResult
    public func updateComposerInput(_ input: TelegramComposerInput, contextID: UUID, chatID: Int64) -> Bool {
        guard contextID == accountGeneration, selectedChatID == chatID, phase == .ready, !isComposerSuspended,
              !isForwardComposerLocked, composerDraftRecoveryError == nil else { return false }
        setComposerInput(input)
        return true
    }

    private func composerSubmission(formatted: TelegramFormattedText, accountID: Int64, chatID: Int64) -> TelegramComposerDraft? {
        guard let snapshot = drafts.snapshot(accountID: accountID, chatID: chatID),
              snapshot.input.formattedText == formatted else { return nil }
        return snapshot
    }

    private func replyText(_ action: TelegramMessageAction) -> TelegramFormattedText? {
        switch action {
        case let .reply(text): return try? TelegramFormattedText(text: text)
        case let .replyFormatted(value): return value
        default: return nil
        }
    }

    private func persistComposerDraft(_ snapshot: TelegramComposerDraft) {
        let key = ComposerDraftKey(accountID: snapshot.accountID, chatID: snapshot.chatID)
        unsavedComposerDrafts[key] = snapshot
        guard let repository = composerDraftRepository, repository.accountID == snapshot.accountID else { return }
        let context = composerDraftGeneration
        repository.save(snapshot) { [weak self] result in
            guard let self else { return }
            if case .success = result, self.unsavedComposerDrafts[key]?.revision == snapshot.revision {
                self.unsavedComposerDrafts[key] = nil
                if !self.canRetryComposerDraftPersistence, self.error == self.composerPersistenceError { self.error = nil }
            }
            guard self.composerDraftGeneration == context,
                  self.draftAccountID == snapshot.accountID,
                  self.drafts.snapshot(accountID: snapshot.accountID, chatID: snapshot.chatID)?.revision == snapshot.revision else { return }
            if case .failure = result, self.unsavedComposerDrafts[key]?.revision == snapshot.revision {
                self.error = self.composerPersistenceError
            }
        }
    }

    public func retryComposerDraftPersistence() {
        guard let accountID = draftAccountID, composerDraftRepository?.accountID == accountID else { return }
        for snapshot in Array(unsavedComposerDrafts.values) where snapshot.accountID == accountID {
            guard snapshot.forwardDisposition == nil || snapshot.forwardDisposition == .prepared else { continue }
            guard drafts.snapshot(accountID: accountID, chatID: snapshot.chatID)?.revision == snapshot.revision else { continue }
            persistComposerDraft(snapshot)
        }
    }

    // Binding is account-scoped. Already started writes retain the original
    // Postbox and complete even after this account is disconnected.
    func bindComposerDraftRepository(_ repository: (any TelegramComposerDraftRepository)?) {
        composerDraftGeneration = UUID()
        composerDraftLoadID = nil
        isRestoringComposerDraft = false
        composerDraftRecoveryError = nil
        composerDraftLoad.set(nil)
        composerDraftRepository = repository
        retryComposerDraftPersistence()
        restoreComposerDraft()
    }

    private func restoreComposerDraft(forceForwardReceipt: Bool = false) {
        let retryFailedLoad = composerDraftRecoveryError != nil
        composerDraftRecoveryError = nil
        composerDraftLoadID = nil
        isRestoringComposerDraft = false
        composerDraftLoad.set(nil)
        guard let chatID = selectedChatID, let accountID = draftAccountID,
              let repository = composerDraftRepository, repository.accountID == accountID else { return }
        let current = drafts.snapshot(accountID: accountID, chatID: chatID)
        guard current == nil || retryFailedLoad || (current?.forwardIntent != nil && (current?.forwardDisposition != .prepared || forceForwardReceipt)) else { return }
        let expectedRevision = current?.revision
        let requestID = UUID(), context = composerDraftGeneration, accountContext = accountGeneration
        composerDraftLoadID = requestID
        isRestoringComposerDraft = true
        let disposable = repository.load(chatID: chatID) { [weak self] result in
            guard let self, self.composerDraftLoadID == requestID, self.composerDraftGeneration == context,
                  self.accountGeneration == accountContext, self.draftAccountID == accountID,
                  self.selectedChatID == chatID else { return }
            self.composerDraftLoadID = nil
            self.isRestoringComposerDraft = false
            defer { self.restorePendingUpload() }
            switch result {
            case let .success(snapshot):
                if self.drafts.restore(snapshot, accountID: accountID, chatID: chatID, expectedRevision: expectedRevision) {
                    self.displayComposerInput(self.drafts.snapshot(accountID: accountID, chatID: chatID)?.input ?? .empty)
                    self.refreshComposerReply()
                    self.refreshComposerForward()
                }
                self.applyPendingForwardStage()
            case .failure:
                self.pendingForwardStage = nil
                let message = "Не удалось открыть сохранённый черновик. Данные на диске не изменены."
                self.composerDraftRecoveryError = message; self.error = message
            }
        }
        if composerDraftLoadID == requestID { composerDraftLoad.set(disposable) } else { disposable.dispose() }
    }

    func bindPendingUploadRecovery(_ store: (any TelegramUploadRecoveryStore)?, replyProvider: (any TelegramComposerReplyProvider)?) {
        cancelPendingRecovery(); pendingRecoveryAttempt = nil
        pendingRecoveryStore = store; pendingReplyProvider = replyProvider
        restorePendingUpload()
    }

    private func cancelPendingRecovery() {
        pendingRecoveryID = UUID(); pendingRecoveryTask?.cancel(); pendingRecoveryTask = nil
        pendingRecoveryDeadline?.cancel(); pendingRecoveryDeadline = nil
        isRestoringPendingUpload = false; pendingUploadRecoveryError = nil
    }

    public func retryPendingUploadRecovery() {
        cancelPendingRecovery(); pendingRecoveryAttempt = nil; restorePendingUpload()
    }

    private func restorePendingUpload() {
        guard composerDraftLoadID == nil, !isRestoringPendingUpload,
              let accountID = draftAccountID, let chatID = selectedChatID,
              let store = pendingRecoveryStore, store.accountID == accountID,
              upload.phase == .idle,
              pendingRecoveryAttempt?.account != accountID || pendingRecoveryAttempt?.chat != chatID else { return }
        pendingRecoveryAttempt = (accountID, chatID)
        let request = UUID(), context = accountGeneration
        pendingRecoveryID = request; isRestoringPendingUpload = true; pendingUploadRecoveryError = nil
        pendingRecoveryDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.pendingRecoveryID == request, self.isRestoringPendingUpload else { return }
            self.cancelPendingRecovery(); self.pendingUploadRecoveryError = "Не удалось открыть подготовленное вложение. Повторите восстановление."
        }
        pendingRecoveryTask = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool { !Task.isCancelled && self.pendingRecoveryID == request && self.accountGeneration == context && self.draftAccountID == accountID && self.selectedChatID == chatID }
            defer {
                if self.pendingRecoveryID == request {
                    self.pendingRecoveryTask = nil; self.pendingRecoveryDeadline?.cancel(); self.pendingRecoveryDeadline = nil
                    self.isRestoringPendingUpload = false
                }
            }
            do {
                guard let draft = try await store.load(chatID: chatID), current() else { return }
                guard draft.isValid, draft.accountID == accountID, draft.chatID == chatID else { throw TelegramUploadFileError.unavailable }
                switch draft.disposition {
                case .cancelled: return
                case .accepted:
                    if let original = draft.originalDraft { self.acknowledgeComposerDraft(formatted: original.input.formattedText, submitted: original) }
                    return
                case .prepared, .submissionStarted: break
                }
                var source: TelegramMessageActionSource?
                if let target = draft.replyTarget {
                    source = await self.resolvePendingReply(target, chatID: chatID, accountID: accountID)
                    guard current() else { return }
                    if source == nil, draft.disposition == .prepared { throw TelegramUploadFileError.unavailable }
                }
                let file = try await store.restoreFile(draft: draft)
                guard current() else { try TelegramUploadFileIO.discard(file); return }
                let target = TelegramUploadTarget(accountID: accountID, chatID: chatID, title: draft.title, replySource: source)
                guard self.upload.restore(draft: draft, file: file, target: target) else {
                    try TelegramUploadFileIO.discard(file); throw TelegramUploadFileError.unavailable
                }
            } catch {
                if current() { self.pendingUploadRecoveryError = "Не удалось восстановить подготовленное вложение. Черновик сохранён. Повторите восстановление." }
            }
        }
    }

    private func resolvePendingReply(_ target: TelegramComposerReplyTarget, chatID: Int64, accountID: Int64) async -> TelegramMessageActionSource? {
        guard let provider = pendingReplyProvider, provider.accountID == accountID else { return nil }
        return await withCheckedContinuation { continuation in
            let disposable = MetaDisposable()
            var completed = false
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard !completed else { return }; completed = true; disposable.dispose(); continuation.resume(returning: nil)
            }
            disposable.set(provider.resolve(target: target, chatID: chatID) { value in
                guard !completed else { return }; completed = true; timeout.cancel(); disposable.dispose()
                guard let source = value?.source, source.accountID == accountID, source.chatID == chatID,
                      source.canReply, !source.fingerprint.isEmpty, TelegramComposerReplyTarget(source: source) == target,
                      (source.peerID == chatID || source.metadata.migrationChatID == chatID) else { continuation.resume(returning: nil); return }
                continuation.resume(returning: source)
            })
        }
    }

    private func acknowledgeComposerDraft(formatted: TelegramFormattedText, submitted: TelegramComposerDraft) {
        guard submitted.input.formattedText == formatted,
              let cleared = drafts.acknowledge(sentInput: submitted.input, revision: submitted.revision,
            accountID: submitted.accountID, chatID: submitted.chatID) else { return }
        persistComposerDraft(cleared)
        if draftAccountID == submitted.accountID, selectedChatID == submitted.chatID {
            displayComposerInput(.empty); refreshComposerReply()
        }
    }

    private func refreshComposerReply(initial: TelegramComposerReply? = nil) {
        let target = isComposerSuspended ? nil : draftAccountID.flatMap { accountID in
            selectedChatID.flatMap { drafts.snapshot(accountID: accountID, chatID: $0)?.replyTarget }
        }
        composerReply.select(target: target, chatID: selectedChatID, initial: initial)
    }

    private func refreshComposerForward() {
        let snapshot = draftAccountID.flatMap { accountID in
            selectedChatID.flatMap { drafts.snapshot(accountID: accountID, chatID: $0) }
        }
        composerForwardIntent = snapshot?.forwardIntent
        composerForwardDisposition = snapshot?.forwardDisposition
        composerForward.select(isComposerSuspended ? nil : snapshot)
    }

    /// Staging navigates to the recipient; it never enqueues a message.
    @discardableResult
    public func stageMessageForward(source: TelegramMessageActionSource, destinationChatID: Int64, contextID: UUID) -> Bool {
        stageMessageForwards(sources: [source], destinationChatID: destinationChatID, contextID: contextID)
    }

    @discardableResult
    public func stageMessageForwards(sources: [TelegramMessageActionSource], destinationChatID: Int64, contextID: UUID) -> Bool {
        guard contextID == accountGeneration, phase == .ready, !isBusy, !isForwardComposerLocked,
              !isRestoringComposerDraft, composerDraftRecoveryError == nil,
              !isRestoringPendingUpload, pendingUploadRecoveryError == nil, upload.phase == .idle,
              !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
              !sources.isEmpty, sources.allSatisfy({ $0.accountID == draftAccountID && $0.chatID == selectedChatID && $0.canForward }),
              let chatID = selectedChatID, knownChats[chatID] != nil,
              let destination = forwardDestinations.first(where: { $0.id == destinationChatID }) else { return false }
        let intent = TelegramComposerForwardIntent(sources: sources.map(TelegramComposerForwardSource.init(source:)))
        guard intent.isValid else { return false }
        knownChats[destinationChatID] = destination
        pendingForwardStage = (contextID, destinationChatID, intent, nil)
        selectedChatID = destinationChatID
        applyPendingForwardStage()
        messageSelection.cancel()
        return true
    }

    private var canChangeMessageSelection: Bool {
        phase == .ready && !isBusy && !historyPage.isLoading && !historyPage.timedOut && !search.hasMessageQuery &&
        !isRestoringComposerDraft && composerDraftRecoveryError == nil && !isForwardComposerLocked &&
        !isRestoringPendingUpload && pendingUploadRecoveryError == nil && upload.phase == .idle &&
        !messageActions.isBusy && messageActions.phase != .uncertain && !selectedMessagesDeletionBlocksActions
    }

    @discardableResult
    public func toggleMessageGroupSelection(group: TelegramHistoryItem, sessionID: UUID?, expectedRevision: UUID?,
                                           contextID: UUID, windowID: UUID, extendingRange: Bool = false) -> Bool {
        guard canChangeMessageSelection, contextID == accountGeneration, historyWindowID == windowID,
              group.isAlbum, let current = historyItems.first(where: { $0.id == group.id }), current == group,
              zip(current.messages, group.messages).allSatisfy({ fresh, frozen in
                  fresh.text.utf8.elementsEqual(frozen.text.utf8) &&
                  fresh.actionMetadata?.fingerprint.utf8.elementsEqual(frozen.actionMetadata?.fingerprint.utf8 ?? "".utf8) == true
              }) else { return false }
        let sources = current.messages.compactMap { actionSource(for: $0) }
        guard sources.count == current.messages.count else { return false }
        if let sessionID, let expectedRevision {
            guard messageSelection.session?.id == sessionID, messageSelection.session?.revision == expectedRevision else { return false }
            cancelMessageSelectionRange(); selectedMessagesCopy.cancel()
            let changed = messageSelection.toggleGroup(sources: sources, sessionID: sessionID, contextID: contextID,
                expectedRevision: expectedRevision, extendingRange: extendingRange)
            if changed { resolveMessageSelectionRange(windowID: windowID) }
            return changed
        }
        guard sessionID == nil, expectedRevision == nil, messageSelection.session == nil else { return false }
        return messageSelection.beginGroup(sources: sources, contextID: contextID, extendingRange: extendingRange)
    }

    @discardableResult
    public func beginMessageSelection(messageID: String, contextID: UUID, windowID: UUID, extendingRange: Bool = false) -> Bool {
        guard canChangeMessageSelection, contextID == accountGeneration, historyWindowID == windowID,
              messageSelection.session == nil, let message = messages.first(where: { $0.id == messageID }),
              let source = actionSource(for: message) else { return false }
        return messageSelection.begin(source: source, contextID: contextID, extendingRange: extendingRange)
    }

    @discardableResult
    public func toggleMessageSelection(messageID: String, sessionID: UUID, contextID: UUID, windowID: UUID, extendingRange: Bool = false) -> Bool {
        guard canChangeMessageSelection, contextID == accountGeneration, historyWindowID == windowID,
              messageSelection.session?.id == sessionID,
              let message = messages.first(where: { $0.id == messageID }), let source = actionSource(for: message) else { return false }
        cancelMessageSelectionRange()
        selectedMessagesCopy.cancel()
        let changed = messageSelection.toggle(source: source, sessionID: sessionID, contextID: contextID, extendingRange: extendingRange)
        if changed { resolveMessageSelectionRange(windowID: windowID) }
        return changed
    }

    func bindMessageSelectionRangeProvider(_ provider: (any TelegramMessageSelectionRangeProvider)?) {
        cancelMessageSelectionRange()
        selectionRangeProvider = provider
    }

    private func cancelMessageSelectionRange() {
        messageSelection.cancelRange()
        selectionRangeDeadline?.cancel(); selectionRangeDeadline = nil
        selectionRangeDisposable.set(nil)
    }

    private func resolveMessageSelectionRange(windowID: UUID) {
        guard let request = messageSelection.rangeRequest else { return }
        guard let provider = selectionRangeProvider, provider.accountID == request.accountID else {
            messageSelection.failRange(request: request); return
        }
        selectionRangeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.messageSelection.rangeRequest == request else { return }
            self.messageSelection.failRange(request: request)
            self.cancelMessageSelectionRange()
        }
        let lease = provider.resolve(request: request) { [weak self] sources in
            guard let self, self.messageSelection.rangeRequest == request else { return }
            guard self.canChangeMessageSelection, self.accountGeneration == request.contextID,
                  self.draftAccountID == request.accountID, self.selectedChatID == request.chatID,
                  self.historyWindowID == windowID else {
                self.cancelMessageSelectionRange(); return
            }
            _ = self.messageSelection.applyRange(sources: sources, request: request)
            self.cancelMessageSelectionRange()
        }
        // A provider may finish synchronously before returning its disposable.
        if messageSelection.rangeRequest == request { selectionRangeDisposable.set(lease) }
        else { lease.dispose() }
    }

    public func cancelMessageSelection(sessionID: UUID, contextID: UUID) {
        guard contextID == accountGeneration, messageSelection.session?.id == sessionID else { return }
        guard !selectedMessagesDeletionBlocksActions else { return }
        cancelMessageSelectionRange()
        selectedMessagesCopy.cancel()
        messageSelection.cancel()
    }

    private func currentMessageSelection(sessionID: UUID, contextID: UUID, revision: UUID) -> TelegramMessageSelectionSession? {
        guard phase == .ready, contextID == accountGeneration, let session = messageSelection.session,
              session.id == sessionID, session.revision == revision, session.contextID == contextID,
              session.accountID == draftAccountID, session.chatID == selectedChatID else { return nil }
        return session
    }

    @discardableResult
    public func copySelectedMessages(sessionID: UUID, contextID: UUID, expectedRevision: UUID,
                                     receive: @escaping @MainActor (String) -> Void) -> Bool {
        guard canChangeMessageSelection, !messageSelection.isResolvingRange,
              let session = currentMessageSelection(sessionID: sessionID, contextID: contextID, revision: expectedRevision),
              session.canCopy else { return false }
        return selectedMessagesCopy.start(request: .init(session: session), isCurrent: { [weak self] in
            guard let self, !self.selectedMessagesDeletionBlocksActions else { return false }
            return self.currentMessageSelection(sessionID: sessionID, contextID: contextID, revision: expectedRevision)?.canCopy == true
        }, receive: receive)
    }

    @discardableResult
    public func deleteSelectedMessages(forEveryone: Bool, sessionID: UUID, contextID: UUID, expectedRevision: UUID) -> Bool {
        guard canChangeMessageSelection, !selectedMessagesCopy.isBusy, !messageSelection.isResolvingRange,
              let session = currentMessageSelection(sessionID: sessionID, contextID: contextID, revision: expectedRevision),
              forEveryone ? session.canDeleteForEveryone : session.canDeleteLocally else { return false }
        selectedDeleteEditSession = messageEditSessions[session.chatID]
        return selectedMessagesDelete.perform(request: .init(session: session, forEveryone: forEveryone))
    }

    @discardableResult
    public func forwardMessageToSaved(source: TelegramMessageActionSource, contextID: UUID) -> Bool {
        guard messageSelection.session == nil else { return false }
        return forwardToSaved(sources: [source], contextID: contextID, selection: nil)
    }
    @discardableResult
    public func forwardSelectedMessagesToSaved(sessionID: UUID, contextID: UUID, expectedRevision: UUID) -> Bool {
        guard let selected = currentMessageSelection(sessionID: sessionID, contextID: contextID, revision: expectedRevision),
              selected.canForward else { return false }
        return forwardToSaved(sources: selected.sources, contextID: contextID, selection: selected)
    }
    private func forwardToSaved(sources: [TelegramMessageActionSource], contextID: UUID,
                                selection: TelegramMessageSelectionSession?) -> Bool {
        guard canChangeMessageSelection, !messageSelection.isResolvingRange, contextID == accountGeneration,
              let accountID = draftAccountID, !sources.isEmpty,
              sources.allSatisfy({ $0.accountID == accountID && $0.chatID == selectedChatID && $0.canForward }) else { return false }
        let request = TelegramSavedMessagesForwardRequest(contextID: contextID, accountID: accountID,
            sources: sources.map(TelegramComposerForwardSource.init(source:)))
        guard request.isValid, !savedMessagesForward.isBusy, savedMessagesForward.phase != .uncertain else { return false }
        savedForwardSelection = (request.id, selection)
        return savedMessagesForward.perform(request)
    }

    @discardableResult
    public func stageSelectedMessagesForward(destinationChatID: Int64, sessionID: UUID, contextID: UUID, expectedRevision: UUID? = nil) -> Bool {
        guard !messageSelection.isResolvingRange, contextID == accountGeneration, let session = messageSelection.session,
              session.id == sessionID, session.contextID == contextID, session.accountID == draftAccountID,
              session.chatID == selectedChatID, session.canForward,
              expectedRevision == nil || expectedRevision == session.revision else { return false }
        return stageMessageForwards(sources: session.sources, destinationChatID: destinationChatID, contextID: contextID)
    }

    private func applyPendingForwardStage() {
        guard let pending = pendingForwardStage, !isRestoringComposerDraft else { return }
        guard pending.context == accountGeneration, pending.destination == selectedChatID,
              let accountID = draftAccountID else { pendingForwardStage = nil; return }
        pendingForwardStage = nil
        let current = drafts.snapshot(accountID: accountID, chatID: pending.destination)
        guard current?.forwardDisposition == nil || current?.forwardDisposition == .prepared else {
            error = "В этом диалоге уже есть пересылка с неподтверждённым результатом. Черновик сохранён."; return
        }
        if let changed = drafts.setForwardIntent(pending.intent, accountID: accountID, chatID: pending.destination) {
            persistComposerDraft(changed)
        }
        if let origin = pending.origin,
           drafts.snapshot(accountID: accountID, chatID: origin.chat)?.forwardIntent?.id == origin.intent,
           let cleared = drafts.setForwardIntent(nil, accountID: accountID, chatID: origin.chat) { persistComposerDraft(cleared) }
        refreshComposerForward()
    }

    public func cancelComposerForward() {
        guard !isForwardComposerLocked, let accountID = draftAccountID, let chatID = selectedChatID else { return }
        if let changed = drafts.setForwardIntent(nil, accountID: accountID, chatID: chatID) { persistComposerDraft(changed) }
        refreshComposerForward()
    }

    @discardableResult
    public func updateForwardOption(_ option: TelegramForwardOption, intentID: UUID, contextID: UUID,
                                    expectedChatID: Int64, expectedRevision: UUID) -> Bool {
        guard contextID == accountGeneration, !isForwardComposerLocked,
              let accountID = draftAccountID, let chatID = selectedChatID, chatID == expectedChatID,
              composerForwardRevision == expectedRevision,
              let intent = composerForwardIntent, intent.id == intentID else { return false }
        if case .captionsHidden = option, !composerForward.previews.contains(where: \.hasCaption) { return false }
        if let changed = drafts.setForwardIntent(intent.applying(option), accountID: accountID, chatID: chatID) {
            persistComposerDraft(changed)
        }
        refreshComposerForward()
        return true
    }

    public func updateForwardOptions(hideNames: Bool, hideCaptions: Bool, intentID: UUID, contextID: UUID) {
        guard contextID == accountGeneration, !isForwardComposerLocked,
              let accountID = draftAccountID, let chatID = selectedChatID,
              let intent = composerForwardIntent, intent.id == intentID else { return }
        let changedIntent = TelegramComposerForwardIntent(id: intent.id, sources: intent.sources,
            hideNames: hideNames, hideCaptions: hideCaptions, explicitHideNames: hideNames)
        if let changed = drafts.setForwardIntent(changedIntent, accountID: accountID, chatID: chatID) { persistComposerDraft(changed) }
        refreshComposerForward()
    }

    @discardableResult
    public func moveComposerForward(to destinationChatID: Int64, intentID: UUID, contextID: UUID,
                                    expectedRevision: UUID? = nil, expectedOriginChatID: Int64? = nil) -> Bool {
        guard contextID == accountGeneration, !isForwardComposerLocked,
              expectedRevision == nil || expectedRevision == composerForwardRevision,
              expectedOriginChatID == nil || expectedOriginChatID == selectedChatID,
              let intent = composerForwardIntent, intent.id == intentID else { return false }
        if destinationChatID == savedMessagesChatID {
            guard canChangeMessageSelection, messageSelection.session == nil,
                  let accountID = draftAccountID, let chatID = selectedChatID, let revision = composerForwardRevision,
                  !savedMessagesForward.isBusy, savedMessagesForward.phase != .uncertain,
                  (isSyntheticPreview && composerDraftRepository == nil) || unsavedComposerDrafts[ComposerDraftKey(accountID: accountID, chatID: chatID)] == nil else { return false }
            let request = TelegramSavedMessagesForwardRequest(contextID: contextID, accountID: accountID, sources: intent.sources,
                origin: .init(chatID: chatID, revision: revision, intentID: intent.id))
            guard request.isValid else { return false }
            savedForwardSelection = (request.id, nil)
            return savedMessagesForward.perform(request)
        }
        guard let destination = forwardDestinations.first(where: { $0.id == destinationChatID }) else { return false }
        guard destinationChatID != selectedChatID else { return true }
        // Another recipient keeps the old chat's ordinary comment/reply.
        guard let originChat = selectedChatID else { return false }
        knownChats[destinationChatID] = destination
        pendingForwardStage = (contextID, destinationChatID,
            TelegramComposerForwardIntent(sources: intent.sources, hideNames: intent.hideNames, hideCaptions: intent.hideCaptions,
                explicitHideNames: intent.explicitHideNames),
            (originChat, intentID))
        selectedChatID = destinationChatID
        applyPendingForwardStage()
        return true
    }

    @discardableResult
    public func sendComposerForward() -> Bool {
        guard composerCanSend, composerForwardIntent != nil, phase == .ready,
              !isBusy, !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions, upload.phase == .idle,
              let accountID = draftAccountID, let chatID = selectedChatID,
              let snapshot = drafts.snapshot(accountID: accountID, chatID: chatID) else { return false }
        return composerForward.submit(snapshot)
    }

    /// Re-read the local receipt; this never submits a new operation.
    public func refreshForwardReceipt() {
        guard composerForwardIntent != nil, !isRestoringComposerDraft else { return }
        if isForwardComposerLocked { restoreComposerDraft(forceForwardReceipt: true) }
        else { composerForward.retry() }
    }

    public func retryComposerDraftRestore() { restoreComposerDraft() }

    @discardableResult
    public func beginReply(to message: TelegramMessage, contextID: UUID) -> Bool {
        guard messageSelection.session == nil, !isRestoringPendingUpload, composerDraftRecoveryError == nil,
              !isForwardComposerLocked, contextID == accountGeneration, !isBusy, upload.phase == .idle,
              let source = actionSource(for: message), source.canReply, !source.fingerprint.isEmpty,
              source.chatID == source.peerID || source.metadata.migrationChatID == source.chatID else { return false }
        let target = TelegramComposerReplyTarget(source: source)
        guard target.isValid else { return false }
        if let changed = drafts.setReplyTarget(target, accountID: source.accountID, chatID: source.chatID) {
            persistComposerDraft(changed)
        }
        if let session = messageEditSession {
            _ = cancelMessageEdit(sessionID: session.id, contextID: contextID)
        }
        refreshComposerReply(initial: TelegramComposerReply(source: source, author: message.author))
        return true
    }

    public func cancelComposerReply() {
        guard !isForwardComposerLocked, let accountID = draftAccountID, let chatID = selectedChatID else { return }
        if let changed = drafts.setReplyTarget(nil, accountID: accountID, chatID: chatID) { persistComposerDraft(changed) }
        refreshComposerReply()
    }

    /// Explicit opening observes only the selected account's peer view and asks
    /// the native tracker to refresh it. Observation time is not a server ACK.
    public func loadContactProfile() {
        cancelContactProfile()
        guard phase == .ready, let chat = selectedChat, let accountID = draftAccountID else { return }
        let requestID = UUID(), contextID = accountGeneration
        contactProfileRequestID = requestID
        contactProfileState = .loading
        #if DEBUG
        if isSyntheticPreview {
            let profile = peerProfilesPreview ? telegramSyntheticPeerProfile(chat: chat, accountID: accountID)
                : TelegramContactProfile(accountID: accountID, peerID: chat.id,
                displayName: chat.title, username: "synthetic_\(chat.id)", phone: "10000000000",
                isBot: false, observedAt: Date())
            receiveContactProfile(profile, requestID: requestID,
                contextID: contextID, accountID: accountID, chatID: chat.id)
            return
        }
        #endif
        guard let account else { cancelContactProfile(); return }
        contactProfileTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.contactProfileRequestID == requestID else { return }
            self.contactProfileSubscription.set(nil)
            self.contactProfileRequestID = nil
            self.contactProfileTimeout = nil
            self.contactProfileState = .unavailable("Карточка пока не загрузилась. Повторите запрос.")
        }
        contactProfileSubscription.set(telegramPeerProfileSignal(account: account, peerID: chat.id,
            accountID: accountID).start(next: { [weak self] profile in
            MainActor.assumeIsolated {
                self?.receiveContactProfile(profile, requestID: requestID,
                    contextID: contextID, accountID: accountID, chatID: chat.id)
            }
        }))
    }

    func receiveContactProfile(_ profile: TelegramContactProfile?, requestID: UUID,
                               contextID: UUID, accountID: Int64, chatID: Int64) {
        guard phase == .ready, requestID == contactProfileRequestID, contextID == accountGeneration,
              accountID == draftAccountID, chatID == selectedChatID,
              profile == nil || (profile?.accountID == accountID && profile?.peerID == chatID) else { return }
        contactProfileTimeout?.cancel(); contactProfileTimeout = nil
        // The same guarded request owns subsequent native peer/cache updates.
        contactProfileState = profile.map(TelegramContactProfileState.ready)
            ?? .unavailable("Сведения о диалоге пока недоступны. Секретные чаты в этой карточке ещё не поддерживаются.")
    }

    public func isCurrentContactProfile(_ profile: TelegramContactProfile, contextID: UUID) -> Bool {
        phase == .ready && contextID == accountGeneration && profile.accountID == draftAccountID
            && profile.peerID == selectedChatID && contactProfileState == .ready(profile)
    }

    public func openProfilePhotos(_ profile: TelegramContactProfile, contextID: UUID) -> Bool {
        guard isCurrentContactProfile(profile, contextID: contextID) else { return false }
        profilePhotos.open(peerID: profile.peerID)
        return true
    }

    public func cancelContactProfile() {
        profilePhotos.close()
        contactProfileSubscription.set(nil)
        contactProfileTimeout?.cancel(); contactProfileTimeout = nil
        contactProfileRequestID = nil
        contactProfileState = .idle
    }

    private func projectMessageEditSession() {
        messageEditSession = selectedChatID.flatMap { messageEditSessions[$0] }.flatMap {
            $0.contextID == accountGeneration && $0.source.accountID == draftAccountID ? $0 : nil
        }
    }

    @discardableResult
    public func beginMessageEdit(source: TelegramMessageActionSource, author: String, contextID: UUID) -> Bool {
        guard messageSelection.session == nil, contextID == accountGeneration, phase == .ready, !isBusy, !isForwardComposerLocked,
              composerDraftRecoveryError == nil,
              !isRestoringPendingUpload, pendingUploadRecoveryError == nil, upload.phase == .idle,
              !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
              source.accountID == draftAccountID, source.chatID == selectedChatID,
              knownChats[source.chatID] != nil, source.canEdit, !source.fingerprint.isEmpty,
              source.peerID == source.chatID || source.metadata.migrationChatID == source.chatID,
              source.metadata.formattedText?.isEditable != false,
              let formatted = messageFormattedEditDraft(for: source), formatted.isEditable,
              let input = try? TelegramComposerInput(formattedText: formatted) else { return false }
        if let current = messageEditSessions[source.chatID], current.source == source,
           current.contextID == contextID { projectMessageEditSession(); return true }
        messageEditSessions[source.chatID] = TelegramMessageEditSession(source: source, author: author,
            contextID: contextID, input: input)
        projectMessageEditSession()
        return true
    }

    @discardableResult
    public func updateMessageEditInput(_ input: TelegramComposerInput, sessionID: UUID, contextID: UUID) -> Bool {
        guard phase == .ready, contextID == accountGeneration, let current = messageEditSession,
              current.id == sessionID, current.contextID == contextID,
              current.source.accountID == draftAccountID, current.source.chatID == selectedChatID,
              input.formattedText.isEditable else { return false }
        guard current.input != input else { return true }
        messageEditSessions[current.source.chatID] = TelegramMessageEditSession(id: current.id,
            source: current.source, author: current.author, contextID: contextID, input: input)
        editDrafts[EditDraftKey(current.source)] = input.formattedText
        projectMessageEditSession()
        return true
    }

    @discardableResult
    public func cancelMessageEdit(sessionID: UUID, contextID: UUID) -> Bool {
        guard contextID == accountGeneration, let current = messageEditSession,
              current.id == sessionID, current.contextID == contextID,
              current.source.chatID == selectedChatID else { return false }
        editDrafts[EditDraftKey(current.source)] = nil
        messageEditSessions[current.source.chatID] = nil
        projectMessageEditSession()
        return true
    }

    public func messageEditDraft(for source: TelegramMessageActionSource) -> String {
        editDrafts[EditDraftKey(source)]?.text ?? source.text
    }

    public func messageFormattedEditDraft(for source: TelegramMessageActionSource) -> TelegramFormattedText? {
        editDrafts[EditDraftKey(source)] ?? source.metadata.formattedText ?? (try? TelegramFormattedText(text: source.text))
    }

    public func saveMessageEditDraft(_ text: String, source: TelegramMessageActionSource, contextID: UUID) {
        // The plain compatibility API must never erase a rich draft/source.
        guard editDrafts[EditDraftKey(source)]?.entities.isEmpty != false,
              source.metadata.formattedText?.entities.isEmpty != false,
              let value = try? TelegramFormattedText(text: text) else { return }
        saveMessageFormattedEditDraft(value, source: source, contextID: contextID)
    }

    public func saveMessageFormattedEditDraft(_ value: TelegramFormattedText, source: TelegramMessageActionSource, contextID: UUID) {
        guard contextID == accountGeneration, source.accountID == draftAccountID else { return }
        editDrafts[EditDraftKey(source)] = value
    }

    public func actionSource(for message: TelegramMessage) -> TelegramMessageActionSource? {
        guard phase == .ready, let accountID = draftAccountID, let chatID = selectedChatID,
              knownChats[chatID] != nil, let metadata = message.actionMetadata else { return nil }
        return TelegramMessageActionSource(metadata: metadata, accountID: accountID, chatID: chatID)
    }

    @discardableResult
    public func performMessageAction(_ action: TelegramMessageAction, source: TelegramMessageActionSource, contextID: UUID) -> Bool {
        guard messageSelection.session == nil, !isRestoringPendingUpload, composerDraftRecoveryError == nil,
              !isForwardComposerLocked, pendingUploadRecoveryError == nil,
              contextID == accountGeneration, phase == .ready, !isBusy, upload.phase == .idle,
              !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
              source.accountID == draftAccountID, source.chatID == selectedChatID,
              knownChats[source.chatID] != nil else { return false }
        if case let .forward(destination) = action {
            guard let chat = forwardDestinations.first(where: { $0.id == destination }) else { return false }
            knownChats[destination] = chat
        }
        replyComposerSubmission = nil
        if let formatted = replyText(action) {
            guard composerForwardIntent == nil else { return false }
            if let target = drafts.snapshot(accountID: source.accountID, chatID: source.chatID)?.replyTarget {
                guard target == TelegramComposerReplyTarget(source: source), composerReply.resolved?.source == source else { return false }
            }
            if let snapshot = composerSubmission(formatted: formatted, accountID: source.accountID, chatID: source.chatID) {
                replyComposerSubmission = (source, snapshot)
            }
        }
        submittedEditSession = nil
        let edited: TelegramFormattedText?
        switch action {
        case let .edit(value): edited = try? TelegramFormattedText(text: value)
        case let .editFormatted(value): edited = value
        default: edited = nil
        }
        if let edited, let session = messageEditSession, session.source == source,
           session.contextID == contextID, session.input.formattedText == edited {
            submittedEditSession = session
        }
        // Capture before perform: providers may synchronously acknowledge.
        let accepted = messageActions.perform(action, source: source)
        if !accepted { replyComposerSubmission = nil; submittedEditSession = nil }
        return accepted
    }

    public func prepareUpload(source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, caption: String, contextID: UUID) {
        guard let input = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: caption)) else { return }
        prepareUpload(source: source,mode: mode,target: target,captionInput: input,contextID: contextID)
    }

    public func prepareUpload(source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, captionInput: TelegramComposerInput, contextID: UUID) {
        guard messageSelection.session == nil, !isRestoringPendingUpload, pendingUploadRecoveryError == nil, contextID == accountGeneration, phase == .ready, !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
              drafts.snapshot(accountID: target.accountID, chatID: target.chatID)?.forwardIntent == nil,
              selectedChatID != target.chatID || composerDraftRecoveryError == nil,
              target.accountID == draftAccountID, knownChats[target.chatID] != nil, target.hasValidReplySource else { return }
        upload.prepare(source: source, mode: mode, target: target, captionInput: captionInput)
    }

    public func uploadTarget(replyTo source: TelegramMessageActionSource?, contextID: UUID) -> TelegramUploadTarget? {
        guard !isRestoringPendingUpload, pendingUploadRecoveryError == nil, contextID == accountGeneration, composerSupportsAttachments, let target = uploadTarget else { return nil }
        if let replyTarget = drafts.snapshot(accountID: target.accountID, chatID: target.chatID)?.replyTarget {
            guard let source, TelegramComposerReplyTarget(source: source) == replyTarget,
                  composerReply.resolved?.source == source else { return nil }
        }
        let captured = TelegramUploadTarget(accountID: target.accountID, chatID: target.chatID,
            title: target.title, replySource: source)
        return captured.hasValidReplySource ? captured : nil
    }

    private func suspendUploadComposer(target: TelegramUploadTarget, input: TelegramComposerInput, id: UUID) {
        uploadComposerPreparationID = id
        uploadComposerTransfer = nil
        uploadComposerSubmission = nil
        guard target.accountID == draftAccountID,
              let snapshot = drafts.snapshot(accountID: target.accountID, chatID: target.chatID),
              snapshot.input == input,
              snapshot.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else { return }
        uploadComposerTransfer = (id, snapshot)
        if selectedChatID == target.chatID { displayComposerInput(.empty); refreshComposerReply() }
    }

    private func finishUploadComposer(id: UUID) {
        guard uploadComposerPreparationID == id else { return }
        uploadComposerPreparationID = nil
        let transfer = uploadComposerTransfer
        uploadComposerTransfer = nil
        uploadComposerSubmission = nil
        guard let transfer, transfer.draft.accountID == draftAccountID, transfer.draft.chatID == selectedChatID else { return }
        displayComposerInput(drafts.snapshot(accountID: transfer.draft.accountID, chatID: transfer.draft.chatID)?.input ?? .empty)
        refreshComposerReply()
    }

    func captureUploadDraft(target: TelegramUploadTarget, caption: String) {
        guard let formatted = try? TelegramFormattedText(text: caption) else { return }
        captureUploadDraft(target: target,caption: formatted)
    }

    func captureUploadDraft(target: TelegramUploadTarget, caption: TelegramFormattedText) {
        uploadComposerSubmission = nil
        guard target.accountID == draftAccountID else { return }
        if uploadComposerPreparationID != nil {
            guard let transfer = uploadComposerTransfer, transfer.draft.accountID == target.accountID, transfer.draft.chatID == target.chatID,
                  transfer.draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else { return }
            uploadComposerSubmission = (transfer.draft, caption)
            return
        }
        guard let snapshot = drafts.snapshot(accountID: target.accountID, chatID: target.chatID),
              snapshot.input.formattedText == caption,
              snapshot.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else { return }
        uploadComposerSubmission = (snapshot, caption)
    }

    func acknowledgeUpload(target: TelegramUploadTarget, caption: String) {
        guard let formatted = try? TelegramFormattedText(text: caption) else { return }
        acknowledgeUpload(target: target,caption: formatted)
    }

    func acknowledgeUpload(target: TelegramUploadTarget, caption: TelegramFormattedText) {
        guard target.accountID == draftAccountID, let submitted = uploadComposerSubmission,
              submitted.draft.accountID == target.accountID, submitted.draft.chatID == target.chatID,
              submitted.caption == caption else { return }
        uploadComposerSubmission = nil
        acknowledgeComposerDraft(formatted: submitted.draft.input.formattedText, submitted: submitted.draft)
    }

    public func connectUsingSavedAPIConfiguration() {
        guard !isSyntheticPreview else { return }
        guard !isBusy, phase == .configuration else { return }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let configuration = try TelegramAPIFile.load(from: support.appendingPathComponent("Makosh/telegram-api.json"))
            connect(apiID: String(configuration.id), apiHash: configuration.hash)
        } catch {
            self.error = "Не удалось открыть локальные API-данные. Проверьте файл telegram-api.json и права 0600 или введите API ID и API hash вручную."
        }
    }

    isolated deinit {
        selectionRangeDeadline?.cancel()
        selectionRangeDisposable.dispose()
        playback.stop()
        openingTimeout?.cancel()
        chatPageTimeout?.cancel()
        historyPageTimeout?.cancel()
        contactProfileTimeout?.cancel()
        pendingRecoveryTask?.cancel()
        pendingRecoveryDeadline?.cancel()
        account?.shouldBeServiceTaskMaster.set(.single(.never))
        account?.shouldKeepOnlinePresence.set(.single(false))
        account?.network.shouldKeepConnection.set(.single(false))
        for disposable in [session, authState, action, chatList, history, connection, outgoing, contactProfileSubscription, composerDraftLoad] { disposable.dispose() }
    }

    public func connect(apiID: String, apiHash: String) {
        guard !isSyntheticPreview else { return }
        guard !isBusy, phase == .configuration else { return }
        do {
            let configuration = try TelegramAPIConfiguration(id: apiID, hash: apiHash)
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Makosh/Telegram", isDirectory: true)
            let encryption = try TelegramSessionKey.open(directory: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            TelegramRuntime.configureLogging(directory: directory)
            initializeAccountManagement()
            let manager = AccountManager<TelegramAccountManagerTypes>(basePath: directory.appendingPathComponent("accounts-metadata").path, isTemporary: false, isReadOnly: false, useCaches: true, removeDatabaseOnError: false)
            self.configuration = configuration
            self.manager = manager
            self.phase = .connecting
            self.isBusy = true
            self.error = nil
            self.connectionDescription = "Открытие отдельного сеанса"
            let token = generation
            openingTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                guard let self, self.generation == token, self.phase == .connecting else { return }
                self.isBusy = false
                self.phase = .unsupported("Локальный сеанс не открылся за 45 секунд. Остановите подключение и проверьте кэш; Макош не удаляет его автоматически.")
            }
            let arguments = NetworkInitializationArguments(apiId: configuration.id, apiHash: configuration.hash,
                languagesCategory: "macos", appVersion: "Makosh 0.2", voipMaxLayer: 0, voipVersions: [],
                appData: .single(nil), externalRequestVerificationStream: .single([:]),
                externalRecaptchaRequestVerification: { _, _ in .complete() }, autolockDeadine: .single(nil),
                encryptionProvider: OpenSSLEncryptionProvider(), deviceModelName: "Mac", useBetaFeatures: false, isICloudEnabled: false)
            let auxiliary = AccountAuxiliaryMethods(fetchResource: { _, _, _, _ in nil },
                fetchResourceMediaReferenceHash: { _ in .single(nil) }, prepareSecretThumbnailData: { _ in nil }, backgroundUpload: { _, _, _ in .single(nil) })
            session.set((currentAccount(allocateIfNotExists: true, networkArguments: arguments, supplementary: false,
                manager: manager, rootPath: directory.path, auxiliaryMethods: auxiliary, encryptionParameters: encryption)
                |> deliverOnMainQueue).start(next: { [weak self] result in
                    guard let self, self.generation == token else { return }
                    switch result {
                    case .unauthorized(let account): self.observeUnauthorized(account, token: token)
                    case .authorized(let account): self.observeAuthorized(account, token: token)
                    case .upgrading: self.connectionDescription = "Открытие или обновление локального кэша"
                    case nil:
                        self.openingTimeout?.cancel()
                        self.isBusy = false
                        self.phase = .unsupported("Не удалось получить состояние отдельного сеанса. Данные не удалены. Остановите подключение перед следующей попыткой.")
                    }
                }))
        } catch {
            self.error = (error as? TelegramSetupError)?.localizedDescription ?? TelegramSetupError.filesystem.localizedDescription
            self.isBusy = false
            self.phase = .configuration
        }
    }

    public func submitPhone(_ phone: String) {
        guard !isBusy, phase == .phone, let configuration, let manager, let unauthorized else { return }
        let number = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard number.hasPrefix("+"), (8...16).contains(number.count), number.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }) else {
            error = "Введите номер в международном формате: + и цифры без пробелов."; return
        }
        isBusy = true; error = nil
        let token = generation
        let authToken = authorizationGeneration
        action.set((sendAuthorizationCode(accountManager: manager, account: unauthorized, phoneNumber: number,
            apiId: configuration.id, apiHash: configuration.hash, pushNotificationConfiguration: nil,
            firebaseSecretStream: .single([:]), syncContacts: false, disableAuthTokens: true, forcedPasswordSetupNotice: { _ in nil })
            |> timeout(30, queue: .mainQueue(), alternate: .fail(.timeout))
            |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false
                if case let .sentCode(account) = result { self.observeUnauthorized(account, token: token) }
            }, error: { [weak self] failure in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false
                switch failure {
                case .invalidPhoneNumber: self.error = "Telegram не принял номер телефона."
                case .limitExceeded, .phoneLimitExceeded: self.error = "Telegram ограничил попытки. Подождите перед новым запросом."
                case .phoneBanned: self.error = "Этот номер заблокирован Telegram."
                case .timeout: self.error = "Нет ответа Telegram. Код мог быть запрошен; не повторяйте запрос сразу."
                case .appOutdated: self.error = "Telegram требует обновлённый способ входа. Эта версия ядра его не поддерживает."
                case .generic: self.error = "Telegram не завершил запрос кода. Проверьте сеть и собственные API-данные."
                }
            }))
    }

    public func submitCode(_ code: String) {
        guard !isBusy, phase == .code, !code.isEmpty, let manager, let unauthorized,
              let authorizationCode = challenge.authorizationCode(code) else { return }
        isBusy = true; error = nil
        let token = generation
        let authToken = authorizationGeneration
        action.set((authorizeWithCode(accountManager: manager, account: unauthorized, code: authorizationCode, termsOfService: nil, forcedPasswordSetupNotice: { _ in nil })
            |> timeout(30, queue: .mainQueue(), alternate: .fail(.generic))
            |> deliverOnMainQueue).start(next: { [weak self] result in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false
                if case .signUp = result { self.phase = .unsupported("Создание нового аккаунта здесь не реализовано. Используйте уже зарегистрированный аккаунт.") }
            }, error: { [weak self] _ in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false; self.error = "Telegram не завершил проверку кода. Проверьте код, сеть и текущее состояние входа перед повторной попыткой."
            }))
    }

    public func submitPassword(_ password: String) {
        guard !isBusy, case .password = phase, !password.isEmpty, let manager, let unauthorized else { return }
        isBusy = true; error = nil
        let token = generation
        let authToken = authorizationGeneration
        action.set((authorizeWithPassword(accountManager: manager, account: unauthorized, password: password, syncContacts: false)
            |> timeout(30, queue: .mainQueue(), alternate: .fail(.generic))
            |> deliverOnMainQueue).start(error: { [weak self] _ in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }
                self.isBusy = false; self.error = "Telegram не завершил проверку пароля. Проверьте пароль, сеть и ограничения попыток."
            }, completed: { [weak self] in
                guard let self, self.generation == token, self.authorizationGeneration == authToken else { return }; self.isBusy = false
            }))
    }

    public func disconnect() {
        #if DEBUG
        preview = nil
        #endif
        generation = UUID()
        openingTimeout?.cancel(); openingTimeout = nil
        stopAuthorizedAccount()
        for disposable in [session, authState, action, chatList, history, connection, outgoing] { disposable.set(nil) }
        selectedChatID = nil
        account = nil; unauthorized = nil; manager = nil; configuration = nil
        chats = []; messages = []; draft = ""
        isBusy = false; phase = .configuration; error = nil; connectionDescription = "Подключение остановлено; локальный сеанс сохранён"
    }

    public func sendMessage(_ text: String) -> Bool {
        guard let formatted = try? TelegramFormattedText(text: text) else { return false }
        return sendMessage(formatted)
    }

    public func sendMessage(_ formatted: TelegramFormattedText) -> Bool {
        guard messageSelection.session == nil, !isRestoringPendingUpload, !isRestoringComposerDraft, composerDraftRecoveryError == nil,
              composerForwardIntent == nil, pendingUploadRecoveryError == nil,
              let draftAccountID, let chatID = selectedChatID,
              drafts.snapshot(accountID: draftAccountID, chatID: chatID)?.replyTarget == nil else { return false }
        guard !isSyntheticPreview else { error = "Синтетическая проверка: отправка отключена."; return false }
        guard !isBusy, !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions, upload.phase == .idle,
              phase == .ready, let account, let selectedChatID,
              knownChats[selectedChatID] != nil else { return false }
        guard telegramFormattedTextCanSend(formatted) else {
            error = "Текст или его форматирование не поддерживается для отправки. Максимум — 4096 знаков UTF16."; return false
        }
        let token = generation
        let accountToken = accountGeneration
        let chat = selectedChatID
        let accountID = account.peerId.toInt64()
        let submitted = composerSubmission(formatted: formatted, accountID: accountID, chatID: chat)
        isBusy = true; error = nil
        let enqueue = telegramEnqueueOutgoingText(account: account,chatID: chat,formatted: formatted)
        outgoing.set((enqueue |> deliverOnMainQueue).start(next: { [weak self] ids in
            guard let self, self.generation == token, self.accountGeneration == accountToken else { return }
            self.isBusy = false
            guard let ids else { self.error = "Не удалось проверить форматирование перед отправкой. Черновик сохранён."; return }
            if ids.contains(where: { $0 != nil }) {
                if let submitted { self.acknowledgeComposerDraft(formatted: formatted, submitted: submitted) }
            } else { self.error = "Не удалось подтвердить постановку в очередь. Черновик сохранён." }
        }))
        return true // Accepted for enqueue; only its acknowledgement clears the draft.
    }

    private func observeUnauthorized(_ account: UnauthorizedAccount, token: UUID) {
        openingTimeout?.cancel(); openingTimeout = nil
        stopAuthorizedAccount()
        authorizationGeneration = UUID()
        let authToken = authorizationGeneration
        self.unauthorized = account
        self.account = nil
        self.isBusy = false
        self.connectionDescription = "Вход в отдельный сеанс Макоша"
        authState.set((account.postbox.stateView() |> deliverOnMainQueue).start(next: { [weak self] view in
            guard let self, self.generation == token, self.authorizationGeneration == authToken, let state = view.state as? UnauthorizedAccountState else { return }
            switch state.contents {
            case .empty, .phoneEntry: self.phase = .phone
            case let .confirmationCodeEntry(_, type, _, _, _, _, _, _):
                self.challenge = TelegramAuthorizationChallenge(type: type)
                self.codeExplanation = self.challenge.explanation
                self.phase = self.challenge.phase
            case .passwordEntry(let hint, _, _, _, _): self.phase = .password(hint: hint)
            case .signUp: self.phase = .unsupported("Регистрация нового аккаунта не реализована.")
            case .passwordRecovery, .awaitingAccountReset: self.phase = .unsupported("Восстановление и сброс аккаунта выполняйте в официальном клиенте Telegram.")
            case .payment: self.phase = .unsupported("Telegram запросил платный способ входа. Макош не выполняет оплату.")
            }
        }))
    }

    private func observeAuthorized(_ account: Account, token: UUID) {
        openingTimeout?.cancel(); openingTimeout = nil
        guard self.account !== account else { return }
        stopAuthorizedAccount()
        authorizationGeneration = UUID()
        action.set(nil)
        self.unauthorized = nil; self.account = account
        bindMessageSelectionRangeProvider(TelegramPostboxSelectionRangeProvider(postbox: account.postbox, accountID: account.peerId.toInt64()))
        let replyProvider = TelegramPostboxComposerReplyProvider(postbox: account.postbox, accountID: account.peerId.toInt64())
        composerReply.bind(replyProvider)
        composerForward.bind(TelegramEngineForwardProvider(account: account))
        let recovery = TelegramPendingUploadSession(repository: TelegramPostboxPendingUploadRepository(postbox: account.postbox, accountID: account.peerId.toInt64()), files: { [weak self] in
            guard let self else { throw TelegramUploadFileError.unavailable }
            return try self.archive.files.pendingUploadFiles()
        })
        pendingRecoveryStore = recovery; pendingReplyProvider = replyProvider
        refreshComposerReply()
        bindComposerDraftRepository(TelegramPostboxComposerDraftRepository(postbox: account.postbox, accountID: account.peerId.toInt64()))
        // Installs TelegramCore's built-in cloud/secret resource fetcher on this
        // account's MediaBox. Auxiliary nil alone does not install the fallback.
        setupAccount(account)
        avatars.bind(TelegramEngineAvatarProvider(account: account))
        peerStatus.bind(account: account)
        profilePhotos.bind(TelegramEngineProfilePhotoProvider(account: account))
        archive.bind(journal: TelegramEngineArchiveJournal(account: account))
        let mediaProvider = TelegramEngineMediaProvider(account: account)
        self.mediaProvider = mediaProvider
        media.bind(provider: mediaProvider)
        upload.bind(provider: TelegramEngineUploadProvider(account: account), recoveryStore: recovery, requiresRecovery: true)
        restorePendingUpload()
        messageActions.bind(provider: TelegramEngineMessageActionsProvider(account: account))
        selectedMessagesCopy.bind(provider: TelegramPostboxSelectedMessagesCopyProvider(postbox: account.postbox, accountID: account.peerId.toInt64()))
        selectedMessagesDelete.bind(provider: TelegramEngineSelectedMessagesDeleteProvider(account: account))
        savedMessagesForward.bind(TelegramEngineSavedMessagesForwardProvider(account: account))
        historyRead.bind(TelegramEngineHistoryReadProvider(account: account))
        search.bind(account: account)
        search.setFolder(chatFolder)
        let accountToken = accountGeneration
        self.authState.set(nil); self.isBusy = false; self.phase = .ready
        account.shouldBeServiceTaskMaster.set(.single(.always))
        account.shouldKeepOnlinePresence.set(.single(false))
        account.network.shouldKeepConnection.set(.single(true))
        connection.set((account.networkState |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self, self.generation == token, self.accountGeneration == accountToken else { return }
            switch state {
            case .waitingForNetwork: self.connectionDescription = "Ожидание сети"
            case .connecting: self.connectionDescription = "Соединение с Telegram"
            case .updating: self.connectionDescription = "Синхронизация"
            case .online: self.connectionDescription = "Подключено к Telegram"
            }
        }))
        loadChatList(clear: true)
        loadHistory()
    }

    private func stopAuthorizedAccount() {
        bindMessageSelectionRangeProvider(nil)
        cancelContactProfile()
        avatars.bind(nil); peerStatus.bind(account: nil)
        profilePhotos.bind(nil)
        historyRead.bind(nil)
        historyReadIndexes = [:]
        archive.bind(journal: nil)
        playback.stop()
        bindPendingUploadRecovery(nil, replyProvider: nil)
        upload.bind(provider: nil)
        uploadComposerPreparationID = nil; uploadComposerTransfer = nil; uploadComposerSubmission = nil
        messageActions.bind(provider: nil)
        selectedMessagesCopy.bind(provider: nil)
        selectedMessagesDelete.bind(provider: nil)
        savedMessagesForward.bind(nil); savedForwardSelection = nil
        selectedDeleteEditSession = nil
        composerReply.bind(nil)
        composerForward.bind(nil)
        messageSelection.cancel()
        pendingForwardStage = nil
        mediaProvider = nil; historyMediaSources = []
        media.bind(provider: nil)
        search.bind(account: nil)
        accountGeneration = UUID()
        messageEditSessions = [:]; messageEditSession = nil; submittedEditSession = nil; editDrafts = [:]
        account?.shouldBeServiceTaskMaster.set(.single(.never))
        account?.shouldKeepOnlinePresence.set(.single(false))
        account?.network.shouldKeepConnection.set(.single(false))
        for disposable in [chatList, history, connection, outgoing] { disposable.set(nil) }
        chatPageTimeout?.cancel(); chatPageTimeout = nil
        historyPageTimeout?.cancel(); historyPageTimeout = nil
        chatPages.reset(); historyPages.reset()
        chatPage = .idle; historyPage = .idle
        selectedChatID = nil
        bindComposerDraftRepository(nil)
        replyComposerSubmission = nil; uploadComposerSubmission = nil
        account = nil
        knownChats = [:]; chats = []; messages = []; draft = ""
        refreshMediaSources()
    }

    public func loadOlderChats() {
        guard chatPages.canLoadPrevious, let cursor = chatPages.previousCursor else { return }
        loadChatList(anchor: cursor)
    }

    public func loadNewerChats() {
        guard chatPages.canLoadNext, let cursor = chatPages.nextCursor else { return }
        loadChatList(anchor: cursor)
    }

    public func showLatestChats() { loadChatList() }
    public func retryChatPage() { loadChatList(anchor: chatPages.anchor) }

    public func loadOlderMessages() {
        guard historyPages.canLoadPrevious, let cursor = historyPages.previousCursor else { return }
        loadHistory(anchor: cursor, clear: false)
    }

    public func loadNewerMessages() {
        guard historyPages.canLoadNext, let cursor = historyPages.nextCursor else { return }
        loadHistory(anchor: cursor, clear: false)
    }

    public func showLatestMessages() { loadHistory(clear: false) }
    public func retryHistoryPage() { loadHistory(anchor: historyPages.anchor, clear: false) }

    public func openSearchMessage(id: String) {
        // Migrated-group matches have the old peer ID. Postbox includes that
        // associated history; validate the search's selected chat, not the index peer.
        guard let index = search.messageIndex(id: id, inChat: selectedChatID) else { return }
        search.messageQuery = ""
        loadHistory(anchor: index, clear: false, focusID: id)
    }

    public func clearHistoryFocus() { historyFocusID = nil }

    public func cancelMediaLoads() {
        playback.stop()
        #if DEBUG
        if isSyntheticPreview {
            media.bind(provider: TelegramSyntheticMediaProvider())
            refreshMediaSources()
            return
        }
        #endif
        media.bind(provider: mediaProvider)
        refreshMediaSources()
    }

    private func refreshMediaSources() {
        let sources = historyMediaSources + Array(search.mediaSources.values)
        mediaProvider?.sources = Dictionary(sources.map { ($0.attachment.id, $0) }, uniquingKeysWith: { _, last in last })
        let attachments = (messages + search.messages).flatMap(\.attachments)
        playback.retain(attachments: attachments)
        media.retain(attachments: attachments)
        if let accountID = draftAccountID, !isSyntheticPreview {
            let archivedSources = Dictionary(sources.map { source in
                let id = source.messageID, a = source.attachment
                return (a.id,(MessageArchiveIdentity(service: "telegram",accountID: String(accountID),
                    conversationID: String(id.peerId.toInt64()),messageID: "\(id.namespace):\(id.id)"),
                    MessageArchiveAttachment(id: a.id,kind: a.kind == .photo ? "photo" : a.kind == .file ? "file" : "unsupported",name: a.name,size: a.byteCount)))
            },uniquingKeysWith: { _, last in last })
            media.completedFullFile = { [files = archive.files] id,url,size in
                guard let (identity,attachment) = archivedSources[id] else { return }
                files.accept(file: url,byteCount: size,identity: identity,attachment: attachment)
            }
        } else { media.completedFullFile = nil }
    }

    private func loadChatList(anchor: ChatListIndex? = nil, clear: Bool = false) {
        chatList.set(nil)
        chatPageTimeout?.cancel(); chatPageTimeout = nil
        if clear { chats = [] }
        #if DEBUG
        if let preview {
            let requestID = chatPages.begin(anchor: anchor)
            let page = preview.chats(folder: chatFolder, anchor: anchor)
            receiveChats(page.items, requestID: requestID, previous: page.previous, next: page.next, isLoading: false)
            return
        }
        #endif
        guard let account else { chatPages.reset(); chatPage = .idle; return }
        let token = generation
        let accountToken = accountGeneration
        let folder = chatFolder
        let requestID = chatPages.begin(anchor: anchor)
        chatPage = chatPages.navigation
        updateChatDeadline(requestID: requestID)
        let group: PeerGroupId = folder == .inbox ? .root : Namespaces.PeerGroup.archive
        let signal: Signal<(ChatListView, ViewUpdateType), NoError>
        if let anchor { signal = account.viewTracker.aroundChatListView(groupId: group, index: anchor, count: 50) }
        else { signal = account.viewTracker.tailChatListView(groupId: group, count: 50) }
        chatList.set((signal |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.generation == token, self.accountGeneration == accountToken,
                  self.chatFolder == folder else { return }
            let view = value.0
            let hasHole = view.entries.contains { if case .HoleEntry = $0 { return true }; return false }
            let chats = view.entries.reversed().compactMap { entry -> TelegramChat? in
                guard case let .MessageEntry(data) = entry, let peer = data.renderedPeer.peer else { return nil }
                return TelegramChat(id: peer.id.toInt64(), title: telegramPeerTitle(peer), preview: telegramMessagePreview(data.messages.last), unreadCount: Int(data.readState?.state.count ?? 0),
                    presence: telegramChatPresence(presence: data.presence, accountID: account.peerId.toInt64(),
                        peerID: peer.id.toInt64(), serverTimeOffset: account.network.globalTimeDifference))
            }
            self.receiveChats(chats, requestID: requestID, previous: view.earlierIndex,
                next: view.laterIndex, isLoading: hasHole)
        }))
    }

    private func loadHistory(anchor: MessageIndex? = nil, clear: Bool = true, focusID: String? = nil) {
        cancelMessageSelectionRange()
        playback.stop()
        historyReadIndexes = [:]
        historyFocusID = focusID
        history.set(nil)
        historyPageTimeout?.cancel(); historyPageTimeout = nil
        if clear { messages = []; historyMediaSources = []; refreshMediaSources() }
        #if DEBUG
        if let preview, let selectedChatID, knownChats[selectedChatID] != nil {
            let requestID = historyPages.begin(anchor: anchor)
            let page = preview.messages(chatID: selectedChatID, anchor: anchor)
            prepareSyntheticHistoryReadIndexes(page.items)
            receiveMessages(page.items, requestID: requestID, previous: page.previous, next: page.next, isLoading: false)
            return
        }
        #endif
        guard let account, let selectedChatID, knownChats[selectedChatID] != nil else {
            historyPages.reset(); historyPage = .idle; return
        }
        let token = generation
        let accountToken = accountGeneration
        let chat = selectedChatID
        let requestID = historyPages.begin(anchor: anchor)
        historyPage = historyPages.navigation
        updateHistoryDeadline(requestID: requestID)
        let index: MessageHistoryAnchorIndex = anchor.map { .message($0) } ?? .upperBound
        history.set((account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: PeerId(chat), threadId: nil),
                index: index, anchorIndex: index, count: 50, fixedCombinedReadStates: nil)
            |> deliverOnMainQueue).start(next: { [weak self] value in
                guard let self, self.generation == token, self.accountGeneration == accountToken,
                      self.selectedChatID == chat, self.historyPages.requestID == requestID else { return }
                let view = value.0
                let waiting = view.isLoading || view.isLoadingEarlier ||
                    (view.earlierId == nil && view.holeEarlier) || (view.laterId == nil && view.holeLater)
                let messages = view.entries.map { TelegramMessage($0, accountID: account.peerId.toInt64()) }
                if !messages.isEmpty || !waiting {
                    self.historyMediaSources = view.entries.flatMap { telegramAttachments($0.message) }
                    self.prepareHistoryReadIndexes(view.entries)
                }
                self.receiveMessages(messages, requestID: requestID, previous: view.earlierId,
                    next: view.laterId, isLoading: waiting, hasPreviousGap: view.holeEarlier, hasNextGap: view.holeLater)
            }))
    }

    func receiveChats(_ items: [TelegramChat], requestID: UUID, previous: ChatListIndex?,
                      next: ChatListIndex?, isLoading: Bool) {
        guard chatPages.update(requestID: requestID, previous: previous, next: next,
            isLoading: isLoading, hasPreviousGap: isLoading) else { return }
        chatPage = chatPages.navigation
        updateChatDeadline(requestID: requestID)
        for chat in items { knownChats[chat.id] = chat }
        // Keep the previous window while an empty loading snapshot fills holes.
        // A stable empty snapshot still clears deleted/empty contents.
        if !items.isEmpty || !isLoading { chats = items }
    }

    func receiveMessages(_ items: [TelegramMessage], requestID: UUID, previous: MessageIndex?,
                         next: MessageIndex?, isLoading: Bool, hasPreviousGap: Bool = false,
                         hasNextGap: Bool = false) {
        guard historyPages.update(requestID: requestID, previous: previous, next: next,
            isLoading: isLoading, hasPreviousGap: hasPreviousGap, hasNextGap: hasNextGap) else { return }
        historyPage = historyPages.navigation
        updateHistoryDeadline(requestID: requestID)
        if !items.isEmpty || !isLoading { messages = items }
        if let chatID = selectedChatID {
            messageSelection.observe(sources: items.compactMap(actionSource), contextID: accountGeneration, chatID: chatID)
        }
        if messageSelection.rangeRequest == nil || historyPage.isLoading { cancelMessageSelectionRange() }
        refreshMediaSources()
    }

    private func updateChatDeadline(requestID: UUID) {
        guard chatPage.isLoading else { chatPageTimeout?.cancel(); chatPageTimeout = nil; return }
        guard chatPageTimeout == nil else { return }
        chatPageTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.chatPages.timeout(requestID: requestID) else { return }
            self.chatPageTimeout = nil
            self.chatPage = self.chatPages.navigation
        }
    }

    private func updateHistoryDeadline(requestID: UUID) {
        guard historyPage.isLoading else { historyPageTimeout?.cancel(); historyPageTimeout = nil; return }
        guard historyPageTimeout == nil else { return }
        historyPageTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.historyPages.timeout(requestID: requestID) else { return }
            self.historyPageTimeout = nil
            self.historyPage = self.historyPages.navigation
        }
    }

    #if DEBUG
    /// Explicit, in-memory UI fixture. Does not open accounts, files or Keychain.
    public static func syntheticPreview(albums: Bool = false) -> TelegramModel {
        let model = TelegramModel()
        let pages = TelegramSyntheticPages(albums: albums)
        model.preview = pages
        model.search.useSyntheticPreview(albums: albums)
        model.media.bind(provider: TelegramSyntheticMediaProvider())
        model.upload.bind(provider: TelegramSyntheticUploadProvider())
        model.messageActions.bind(provider: TelegramSyntheticMessageActionsProvider())
        model.selectedMessagesCopy.bind(provider: TelegramSyntheticSelectedMessagesCopyProvider(pages: pages))
        model.selectedMessagesDelete.bind(provider: TelegramSyntheticSelectedMessagesDeleteProvider())
        model.savedMessagesForward.bind(TelegramSyntheticSavedMessagesForwardProvider(pages: pages))
        model.composerReply.bind(TelegramSyntheticComposerReplyProvider(pages: pages))
        model.composerForward.bind(TelegramSyntheticForwardProvider(pages: pages))
        model.bindMessageSelectionRangeProvider(TelegramSyntheticSelectionRangeProvider(pages: pages))
        model.bindSyntheticHistoryRead()
        model.isSyntheticPreview = true
        model.archive.configure(repository: TelegramSyntheticArchiveRepository(), synthetic: true)
        model.phase = .ready
        model.connectionDescription = "Синтетическая UI-проверка • сеть и отправка отключены"
        model.loadChatList(clear: true)
        return model
    }

    public static func syntheticPeerProfilesPreview() -> TelegramModel {
        let model = syntheticPreview()
        model.peerProfilesPreview = true
        return model
    }

    public static func syntheticPeerAppearancePreview() -> TelegramModel {
        let model = syntheticPeerProfilesPreview()
        let observedAt = Date()
        model.preview = TelegramSyntheticPages(presenceObservedAt: observedAt)
        model.search.useSyntheticPreview(presenceObservedAt: observedAt)
        model.loadChatList(clear: true)
        model.avatars.bind(TelegramSyntheticAvatarProvider())
        model.peerStatus.useSyntheticPreview()
        model.profilePhotos.bind(TelegramSyntheticProfilePhotoProvider())
        return model
    }
    #endif

}

private enum TelegramSessionKey {
    static func open(directory: URL) throws -> ValueBoxEncryptionParameters {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.makosh.telegram", kSecAttrAccount as String: "session-encryption-v1"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        let bytes: Data
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 48 else { throw TelegramSetupError.keychain }
            bytes = data
        } else if status == errSecItemNotFound {
            if FileManager.default.fileExists(atPath: directory.path),
               !(try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty { throw TelegramSetupError.missingSessionKey }
            var generated = Data(count: 48)
            guard generated.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 48, $0.baseAddress!) }) == errSecSuccess else { throw TelegramSetupError.keychain }
            var item = query
            item[kSecValueData as String] = generated
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw TelegramSetupError.keychain }
            bytes = generated
        } else { throw TelegramSetupError.keychain }
        guard let key = ValueBoxEncryptionParameters.Key(data: bytes.prefix(32)),
              let salt = ValueBoxEncryptionParameters.Salt(data: bytes.suffix(16)) else { throw TelegramSetupError.keychain }
        return ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt)
    }
}
