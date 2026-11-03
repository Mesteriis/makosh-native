import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Forward staging, options, Saved Messages forwarding and receipts.
extension TelegramModel {
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

    /// Staging navigates to the recipient; it never enqueues a message.
    @discardableResult
    public func stageMessageForward(source: TelegramMessageActionSource, destinationChatID: Int64, contextID: UUID) -> Bool {
        stageMessageForwards(sources: [source], destinationChatID: destinationChatID, contextID: contextID)
    }

    @discardableResult
    public func stageMessageForwards(sources: [TelegramMessageActionSource], destinationChatID: Int64, contextID: UUID) -> Bool {
        guard contextID == conversationGeneration, phase == .ready, !isBusy, !isForwardComposerLocked,
            !isRestoringComposerDraft, composerDraftRecoveryError == nil, serverDraftConflict == nil, !isResolvingServerDraft,
            !isRestoringPendingUpload, pendingUploadRecoveryError == nil, upload.phase == .idle,
            !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
            !sources.isEmpty, sources.allSatisfy({ $0.accountID == draftAccountID && $0.chatID == selectedChatID && $0.canForward }),
            let chatID = selectedChatID, knownChats[chatID] != nil,
            let destination = forwardDestinations.first(where: { $0.id == destinationChatID })
        else { return false }
        let intent = TelegramComposerForwardIntent(sources: sources.map(TelegramComposerForwardSource.init(source:)))
        guard intent.isValid else { return false }
        knownChats[destinationChatID] = destination
        pendingForwardStage = (contextID, destinationChatID, intent, nil)
        selectedChatID = destinationChatID
        applyPendingForwardStage()
        messageSelection.cancel()
        return true
    }

    @discardableResult
    public func forwardMessageToSaved(source: TelegramMessageActionSource, contextID: UUID) -> Bool {
        guard messageSelection.session == nil else { return false }
        return forwardToSaved(sources: [source], contextID: contextID, selection: nil)
    }

    @discardableResult
    public func forwardSelectedMessagesToSaved(sessionID: UUID, contextID: UUID, expectedRevision: UUID) -> Bool {
        guard let selected = currentMessageSelection(sessionID: sessionID, contextID: contextID, revision: expectedRevision),
            selected.canForward
        else { return false }
        return forwardToSaved(sources: selected.sources, contextID: contextID, selection: selected)
    }

    func forwardToSaved(
        sources: [TelegramMessageActionSource], contextID: UUID,
        selection: TelegramMessageSelectionSession?
    ) -> Bool {
        guard canChangeMessageSelection, !messageSelection.isResolvingRange, contextID == conversationGeneration,
            let accountID = draftAccountID, !sources.isEmpty,
            sources.allSatisfy({ $0.accountID == accountID && $0.chatID == selectedChatID && $0.canForward })
        else { return false }
        let request = TelegramSavedMessagesForwardRequest(
            contextID: contextID, accountID: accountID,
            sources: sources.map(TelegramComposerForwardSource.init(source:)))
        guard request.isValid, !savedMessagesForward.isBusy, savedMessagesForward.phase != .uncertain else { return false }
        savedForwardSelection = (request.id, selection)
        return savedMessagesForward.perform(request)
    }

    @discardableResult
    public func stageSelectedMessagesForward(
        destinationChatID: Int64, sessionID: UUID, contextID: UUID, expectedRevision: UUID? = nil
    ) -> Bool {
        guard !messageSelection.isResolvingRange, contextID == conversationGeneration, let session = messageSelection.session,
            session.id == sessionID, session.contextID == contextID, session.accountID == draftAccountID,
            session.chatID == selectedChatID, session.canForward,
            expectedRevision == nil || expectedRevision == session.revision
        else { return false }
        return stageMessageForwards(sources: session.sources, destinationChatID: destinationChatID, contextID: contextID)
    }

    func applyPendingForwardStage() {
        guard let pending = pendingForwardStage, !isRestoringComposerDraft else { return }
        guard pending.context == conversationGeneration, pending.destination == selectedChatID,
            let accountID = draftAccountID
        else {
            pendingForwardStage = nil
            return
        }
        pendingForwardStage = nil
        let current = drafts.snapshot(accountID: accountID, chatID: pending.destination, threadID: selectedThreadID)
        guard current?.forwardDisposition == nil || current?.forwardDisposition == .prepared else {
            error = "В этом диалоге уже есть пересылка с неподтверждённым результатом. Черновик сохранён."
            return
        }
        if let changed = drafts.setForwardIntent(
            pending.intent, accountID: accountID, chatID: pending.destination, threadID: selectedThreadID)
        {
            persistComposerDraft(changed)
        }
        if let origin = pending.origin,
            drafts.snapshot(accountID: accountID, chatID: origin.chat, threadID: origin.thread)?.forwardIntent?.id == origin.intent,
            let cleared = drafts.setForwardIntent(nil, accountID: accountID, chatID: origin.chat, threadID: origin.thread)
        {
            persistComposerDraft(cleared)
        }
        refreshComposerForward()
    }

    public func cancelComposerForward() {
        guard !isForwardComposerLocked, let accountID = draftAccountID, let chatID = selectedChatID else { return }
        if let changed = drafts.setForwardIntent(nil, accountID: accountID, chatID: chatID, threadID: selectedThreadID) {
            persistComposerDraft(changed)
        }
        refreshComposerForward()
    }

    @discardableResult
    public func updateForwardOption(
        _ option: TelegramForwardOption, intentID: UUID, contextID: UUID,
        expectedChatID: Int64, expectedRevision: UUID
    ) -> Bool {
        guard contextID == conversationGeneration, !isForwardComposerLocked,
            let accountID = draftAccountID, let chatID = selectedChatID, chatID == expectedChatID,
            composerForwardRevision == expectedRevision,
            let intent = composerForwardIntent, intent.id == intentID
        else { return false }
        if case .captionsHidden = option, !composerForward.previews.contains(where: \.hasCaption) { return false }
        if let changed = drafts.setForwardIntent(intent.applying(option), accountID: accountID, chatID: chatID, threadID: selectedThreadID)
        {
            persistComposerDraft(changed)
        }
        refreshComposerForward()
        return true
    }

    public func updateForwardOptions(hideNames: Bool, hideCaptions: Bool, intentID: UUID, contextID: UUID) {
        guard contextID == conversationGeneration, !isForwardComposerLocked,
            let accountID = draftAccountID, let chatID = selectedChatID,
            let intent = composerForwardIntent, intent.id == intentID
        else { return }
        let changedIntent = TelegramComposerForwardIntent(
            id: intent.id, sources: intent.sources,
            hideNames: hideNames, hideCaptions: hideCaptions, explicitHideNames: hideNames)
        if let changed = drafts.setForwardIntent(changedIntent, accountID: accountID, chatID: chatID, threadID: selectedThreadID) {
            persistComposerDraft(changed)
        }
        refreshComposerForward()
    }

    @discardableResult
    public func moveComposerForward(
        to destinationChatID: Int64, intentID: UUID, contextID: UUID,
        expectedRevision: UUID? = nil, expectedOriginChatID: Int64? = nil
    ) -> Bool {
        guard contextID == conversationGeneration, !isForwardComposerLocked,
            expectedRevision == nil || expectedRevision == composerForwardRevision,
            expectedOriginChatID == nil || expectedOriginChatID == selectedChatID,
            let intent = composerForwardIntent, intent.id == intentID
        else { return false }
        if destinationChatID == savedMessagesChatID {
            guard canChangeMessageSelection, messageSelection.session == nil,
                let accountID = draftAccountID, let chatID = selectedChatID, let revision = composerForwardRevision,
                !savedMessagesForward.isBusy, savedMessagesForward.phase != .uncertain,
                (isSyntheticPreview && composerDraftRepository == nil)
                    || unsavedComposerDrafts[ComposerDraftKey(accountID: accountID, chatID: chatID, threadID: selectedThreadID)] == nil
            else { return false }
            let request = TelegramSavedMessagesForwardRequest(
                contextID: contextID, accountID: accountID, sources: intent.sources,
                origin: .init(chatID: chatID, threadID: selectedThreadID, revision: revision, intentID: intent.id))
            guard request.isValid else { return false }
            savedForwardSelection = (request.id, nil)
            return savedMessagesForward.perform(request)
        }
        guard let destination = forwardDestinations.first(where: { $0.id == destinationChatID }) else { return false }
        guard destinationChatID != selectedChatID else { return true }
        // Another recipient keeps the old chat's ordinary comment/reply.
        guard let originChat = selectedChatID else { return false }
        knownChats[destinationChatID] = destination
        pendingForwardStage = (
            contextID, destinationChatID,
            TelegramComposerForwardIntent(
                sources: intent.sources, hideNames: intent.hideNames, hideCaptions: intent.hideCaptions,
                explicitHideNames: intent.explicitHideNames),
            (originChat, selectedThreadID, intentID)
        )
        selectedChatID = destinationChatID
        applyPendingForwardStage()
        return true
    }

    @discardableResult
    public func sendComposerForward() -> Bool {
        guard composerCanSend, composerForwardIntent != nil, phase == .ready,
            !isBusy, !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
            upload.phase == .idle,
            let accountID = draftAccountID, let chatID = selectedChatID,
            let snapshot = drafts.snapshot(accountID: accountID, chatID: chatID, threadID: selectedThreadID)
        else { return false }
        return composerForward.submit(snapshot)
    }

    /// Re-read the local receipt; this never submits a new operation.
    public func refreshForwardReceipt() {
        guard composerForwardIntent != nil, !isRestoringComposerDraft else { return }
        if isForwardComposerLocked { restoreComposerDraft(forceForwardReceipt: true) } else { composerForward.retry() }
    }
}
