import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Composer input, local/remote draft persistence, replies and text sending.
extension TelegramModel {
    public var composerInputRevision: UUID? {
        guard let accountID = draftAccountID, let chatID = selectedChatID else { return nil }
        return drafts.snapshot(accountID: accountID, chatID: chatID, threadID: selectedThreadID)?.revision
    }

    /// Compatibility for plain input callers. Native rich input updates the
    /// complete value atomically, including its UTF16 selection.
    public var draft: String {
        get { composerInput.formattedText.text }
        set {
            if newValue.utf8.elementsEqual(draft.utf8) {
                setComposerInput(composerInput)
                return
            }
            guard let value = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: newValue)) else {
                error = "Не удалось сохранить текст ввода."
                return
            }
            setComposerInput(value)
        }
    }

    public var composerCanSend: Bool {
        guard composerHasTopicDestination, messageSelection.session == nil, !isRestoringPendingUpload, !isRestoringComposerDraft,
            composerDraftRecoveryError == nil, serverDraftConflict == nil, !isResolvingServerDraft, pendingUploadRecoveryError == nil
        else { return false }
        if selectedChatID.flatMap(telegramSecretPeerID) != nil {
            guard let session = composerSecretSession, session.canSetTTL, let layer = session.layer,
                composerForwardIntent == nil, !composerReply.preventsSend,
                makoshSecretEntitiesAreLossless(composerInput.formattedText.engineEntities(), layer: layer)
            else { return false }
        } else if let secret = conversationCapabilities?.secret {
            guard secret.state == .active, secret.verification != nil,
                composerInput.formattedText.entities.isEmpty, composerForwardIntent == nil,
                composerReply.state == .none
            else { return false }
        }
        if composerForwardIntent != nil {
            guard !isForwardComposerLocked, composerForward.phase == .ready,
                composerInput.formattedText.text.isEmpty || telegramFormattedTextCanPrepare(composerInput.formattedText),
                let accountID = draftAccountID, let chatID = selectedChatID
            else { return false }
            return (isSyntheticPreview && composerDraftRepository == nil)
                || unsavedComposerDrafts[ComposerDraftKey(accountID: accountID, chatID: chatID, threadID: selectedThreadID)] == nil
        }
        return telegramFormattedTextCanPrepare(composerInput.formattedText)
    }

    var composerHasTopicDestination: Bool {
        guard let snapshot = forumTopics.snapshot, snapshot.accountID == draftAccountID,
            snapshot.chatID == selectedChatID
        else { return true }
        if selectedThreadID != nil { return true }
        // Ordinary All Messages can reply into an observed source topic. Paid
        // consent instead requires an explicitly selected immutable destination.
        return conversationCapabilities?.messageFee == .free && composerReply.resolved?.source.threadID != nil
    }

    var composerIsSecretChat: Bool {
        conversationCapabilities?.secret != nil || selectedChatID.map { PeerId($0).namespace == Namespaces.Peer.SecretChat } == true
    }

    public var composerSecretSession: TelegramSecretSessionSnapshot? {
        guard secretChats.sessionStatus == .ready, let session = secretChats.session,
            session.accountID == draftAccountID, session.chatID == selectedChatID,
            conversationCapabilities?.secret?.regularPeerID == session.regularPeerID,
            conversationCapabilities?.secret?.state == session.state,
            conversationCapabilities?.secret?.verification == session.verification
        else { return nil }
        return session
    }

    public var composerSupportsExtendedMediaOptions: Bool { !composerIsSecretChat }

    public var secretComposerFormattingSupported: Bool {
        guard let layer = composerSecretSession?.layer else { return false }
        return makoshSecretEntitiesAreLossless(composerInput.formattedText.engineEntities(), layer: layer)
    }

    public var conversationReplyQuoteMaximum: Int { composerIsSecretChat ? 0 : replyQuoteMaximumUTF16Count }

    public var composerSupportsCustomEmoji: Bool {
        composerHasTopicDestination
            && (!composerIsSecretChat || (composerSecretSession?.canSetTTL == true && composerSecretSession?.layer == 144))
    }

    public var composerSupportsAttachments: Bool {
        composerHasTopicDestination
            && (!composerIsSecretChat || (composerSecretSession?.canSetTTL == true && (composerSecretSession?.layer ?? 0) >= 46))
            && composerInput.formattedText.isEditable && composerForwardIntent == nil && serverDraftConflict == nil
            && !isResolvingServerDraft
    }

    public var isForwardComposerLocked: Bool {
        guard let intent = composerForwardIntent else { return false }
        let saved = savedMessagesForward.request
        let recoveringSaved = saved == nil && (savedMessagesForward.isBusy || savedMessagesForward.phase == .uncertain)
        let retargetingSaved =
            saved?.accountID == draftAccountID && saved?.origin?.chatID == selectedChatID && saved?.origin?.intentID == intent.id
            && (savedMessagesForward.isBusy || savedMessagesForward.phase == .uncertain)
        return recoveringSaved || retargetingSaved || composerForwardDisposition != .prepared || composerForward.phase == .committing
            || composerForward.phase == .uncertain
    }

    public var composerForwardRevision: UUID? {
        guard let accountID = draftAccountID, let chatID = selectedChatID, composerForwardIntent != nil else { return nil }
        return drafts.snapshot(accountID: accountID, chatID: chatID, threadID: selectedThreadID)?.revision
    }

    struct ComposerDraftKey: Hashable {
        let accountID: Int64
        let chatID: Int64
        var threadID: Int64? = nil
    }

    public var canRetryComposerDraftPersistence: Bool {
        guard let accountID = draftAccountID, composerDraftRepository?.accountID == accountID else { return false }
        return unsavedComposerDrafts.values.contains { $0.accountID == accountID }
    }

    public var isComposerSuspended: Bool {
        guard let transfer = uploadComposerTransfer, transfer.draft.accountID == draftAccountID,
            transfer.draft.chatID == selectedChatID, transfer.draft.threadID == selectedThreadID
        else { return false }
        return drafts.snapshot(accountID: transfer.draft.accountID, chatID: transfer.draft.chatID, threadID: transfer.draft.threadID)?
            .revision == transfer.draft.revision
    }

    func displayComposerInput(_ input: TelegramComposerInput) {
        pendingEmojiInsertion = nil
        customEmojiInsertion = nil
        composerInput = isComposerSuspended ? .empty : input
        refreshCustomEmojiDescriptors()
    }

    func setComposerInput(_ input: TelegramComposerInput) {
        guard !isForwardComposerLocked, !isResolvingServerDraft else { return }
        pendingEmojiInsertion = nil
        customEmojiInsertion = nil
        composerInput = input
        refreshCustomEmojiDescriptors()
        guard let accountID = draftAccountID, let chatID = selectedChatID else { return }
        if let changed = drafts.save(input: input, accountID: accountID, chatID: chatID, threadID: selectedThreadID) {
            persistComposerDraft(changed)
        }
        refreshComposerForward()
    }

    @discardableResult
    public func updateComposerInput(_ input: TelegramComposerInput, contextID: UUID, chatID: Int64) -> Bool {
        guard !voiceRecording.isActive, contextID == conversationGeneration, selectedChatID == chatID, phase == .ready,
            !isComposerSuspended,
            !isForwardComposerLocked, composerDraftRecoveryError == nil, !isResolvingServerDraft
        else { return false }
        setComposerInput(input)
        return true
    }

    func composerSubmission(formatted: TelegramFormattedText, accountID: Int64, chatID: Int64) -> TelegramComposerDraft? {
        guard let snapshot = drafts.snapshot(accountID: accountID, chatID: chatID, threadID: selectedThreadID),
            snapshot.input.formattedText == formatted
        else { return nil }
        return snapshot
    }

    func replyText(_ action: TelegramMessageAction) -> TelegramFormattedText? {
        switch action {
        case let .reply(text): return try? TelegramFormattedText(text: text)
        case let .replyFormatted(value): return value
        default: return nil
        }
    }

    func persistComposerDraft(_ snapshot: TelegramComposerDraft) {
        let key = ComposerDraftKey(accountID: snapshot.accountID, chatID: snapshot.chatID, threadID: snapshot.threadID)
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
                self.drafts.snapshot(accountID: snapshot.accountID, chatID: snapshot.chatID, threadID: snapshot.threadID)?.revision
                    == snapshot.revision
            else { return }
            if case .failure = result, self.unsavedComposerDrafts[key]?.revision == snapshot.revision {
                self.error = self.composerPersistenceError
            }
        }
    }

    public func retryComposerDraftPersistence() {
        guard let accountID = draftAccountID, composerDraftRepository?.accountID == accountID else { return }
        for snapshot in Array(unsavedComposerDrafts.values) where snapshot.accountID == accountID {
            guard snapshot.forwardDisposition == nil || snapshot.forwardDisposition == .prepared else { continue }
            guard drafts.snapshot(accountID: accountID, chatID: snapshot.chatID, threadID: snapshot.threadID)?.revision == snapshot.revision
            else { continue }
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
        refreshConversationFilePolicy()
        retryComposerDraftPersistence()
        restoreComposerDraft()
        refreshServerDraftObservation()
    }

    func restoreComposerDraft(forceForwardReceipt: Bool = false) {
        let retryFailedLoad = composerDraftRecoveryError != nil
        composerDraftRecoveryError = nil
        composerDraftLoadID = nil
        isRestoringComposerDraft = false
        composerDraftLoad.set(nil)
        guard let chatID = selectedChatID, let accountID = draftAccountID,
            let repository = composerDraftRepository, repository.accountID == accountID
        else { return }
        let threadID = selectedThreadID
        let current = drafts.snapshot(accountID: accountID, chatID: chatID, threadID: threadID)
        guard
            current == nil || retryFailedLoad
                || (current?.forwardIntent != nil && (current?.forwardDisposition != .prepared || forceForwardReceipt))
        else { return }
        let expectedRevision = current?.revision
        let requestID = UUID(), context = composerDraftGeneration, accountContext = accountGeneration
        composerDraftLoadID = requestID
        isRestoringComposerDraft = true
        let disposable = repository.load(chatID: chatID, threadID: threadID) { [weak self] result in
            guard let self, self.composerDraftLoadID == requestID, self.composerDraftGeneration == context,
                self.accountGeneration == accountContext, self.draftAccountID == accountID,
                self.selectedChatID == chatID, self.selectedThreadID == threadID
            else { return }
            self.composerDraftLoadID = nil
            self.isRestoringComposerDraft = false
            defer {
                self.restorePendingUpload()
                if let next = self.nextServerDraftUpdate, let draftContext = self.serverDraftContext {
                    self.nextServerDraftUpdate = nil
                    self.receiveServerDraftUpdate(next, context: draftContext)
                }
            }
            switch result {
            case let .success(snapshot):
                if self.drafts.restore(
                    snapshot, accountID: accountID, chatID: chatID, threadID: threadID, expectedRevision: expectedRevision)
                {
                    self.displayComposerInput(
                        self.drafts.snapshot(accountID: accountID, chatID: chatID, threadID: threadID)?.input ?? .empty)
                    self.refreshComposerReply()
                    self.refreshComposerForward()
                }
                self.applyPendingForwardStage()
            case .failure:
                self.pendingForwardStage = nil
                let message = "Не удалось открыть сохранённый черновик. Данные на диске не изменены."
                self.composerDraftRecoveryError = message
                self.error = message
            }
        }
        if composerDraftLoadID == requestID { composerDraftLoad.set(disposable) } else { disposable.dispose() }
    }

    func acknowledgeComposerDraft(formatted: TelegramFormattedText, submitted: TelegramComposerDraft) {
        guard submitted.input.formattedText == formatted,
            let cleared = drafts.acknowledge(
                sentInput: submitted.input, revision: submitted.revision,
                accountID: submitted.accountID, chatID: submitted.chatID, threadID: submitted.threadID)
        else { return }
        persistComposerDraft(cleared)
        if draftAccountID == submitted.accountID, selectedChatID == submitted.chatID, selectedThreadID == submitted.threadID {
            displayComposerInput(.empty)
            refreshComposerReply()
        }
    }

    func refreshComposerReply(initial: TelegramComposerReply? = nil) {
        let target =
            isComposerSuspended
            ? nil
            : draftAccountID.flatMap { accountID in
                selectedChatID.flatMap { drafts.snapshot(accountID: accountID, chatID: $0, threadID: selectedThreadID)?.replyTarget }
            }
        composerReply.select(target: target, chatID: selectedChatID, initial: initial)
    }

    func refreshComposerForward() {
        let snapshot = draftAccountID.flatMap { accountID in
            selectedChatID.flatMap { drafts.snapshot(accountID: accountID, chatID: $0, threadID: selectedThreadID) }
        }
        composerForwardIntent = snapshot?.forwardIntent
        composerForwardDisposition = snapshot?.forwardDisposition
        composerForward.select(isComposerSuspended ? nil : snapshot)
    }

    public func retryComposerDraftRestore() { restoreComposerDraft() }

    @discardableResult
    public func beginReply(to message: TelegramMessage, contextID: UUID, quote: TelegramReplyQuote? = nil) -> Bool {
        guard messageSelection.session == nil, !isRestoringPendingUpload, composerDraftRecoveryError == nil, serverDraftConflict == nil,
            !isResolvingServerDraft,
            !isForwardComposerLocked, contextID == conversationGeneration, !isBusy, upload.phase == .idle,
            let source = actionSource(for: message)?.quoting(quote, maximumLength: replyQuoteMaximumUTF16Count), source.canReply,
            !source.fingerprint.isEmpty,
            source.chatID == source.peerID || source.metadata.migrationChatID == source.chatID
        else { return false }
        let target = TelegramComposerReplyTarget(source: source)
        guard target.isValid else { return false }
        if let changed = drafts.setReplyTarget(target, accountID: source.accountID, chatID: source.chatID, threadID: selectedThreadID) {
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
        if let changed = drafts.setReplyTarget(nil, accountID: accountID, chatID: chatID, threadID: selectedThreadID) {
            persistComposerDraft(changed)
        }
        refreshComposerReply()
    }

    public func sendMessage(_ text: String) -> Bool {
        guard let formatted = try? TelegramFormattedText(text: text) else { return false }
        return sendMessage(formatted)
    }

    public func sendMessage(_ formatted: TelegramFormattedText) -> Bool {
        guard messageSelection.session == nil, !isRestoringPendingUpload, !isRestoringComposerDraft, composerDraftRecoveryError == nil,
            serverDraftConflict == nil, !isResolvingServerDraft,
            composerForwardIntent == nil, pendingUploadRecoveryError == nil,
            let draftAccountID, let chatID = selectedChatID,
            drafts.snapshot(accountID: draftAccountID, chatID: chatID, threadID: selectedThreadID)?.replyTarget == nil
        else { return false }
        guard !isSyntheticPreview else {
            error = "Синтетическая проверка: отправка отключена."
            return false
        }
        guard !isBusy, !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
            upload.phase == .idle,
            phase == .ready, let account, let selectedChatID,
            knownChats[selectedChatID] != nil
        else { return false }
        guard telegramFormattedTextCanPrepare(formatted) else {
            error = "Текст или его форматирование не поддерживается для отправки. Максимум — 4096 знаков UTF16."
            return false
        }
        let token = generation
        let accountToken = accountGeneration
        let chat = selectedChatID
        let accountID = account.peerId.toInt64()
        let submitted = composerSubmission(formatted: formatted, accountID: accountID, chatID: chat)
        isBusy = true
        error = nil
        let enqueue = telegramEnqueueOutgoingText(
            account: account, approval: sendApproval, chatID: chat,
            threadID: selectedThreadID, revision: submitted?.revision ?? UUID(), formatted: formatted)
        outgoing.set(
            (enqueue |> deliverOnMainQueue).start(next: { [weak self] ids in
                guard let self, self.generation == token, self.accountGeneration == accountToken else { return }
                self.isBusy = false
                guard let ids else {
                    self.error = "Не удалось проверить форматирование перед отправкой. Черновик сохранён."
                    return
                }
                if ids.count == 1, ids[0] != nil {
                    if let submitted { self.acknowledgeComposerDraft(formatted: formatted, submitted: submitted) }
                } else {
                    self.error = "Не удалось подтвердить постановку в очередь. Черновик сохранён."
                }
            }))
        return true  // Accepted for enqueue; only its acknowledgement clears the draft.
    }
}
