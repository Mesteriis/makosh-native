import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Inline message editing sessions and message context actions.
extension TelegramModel {
    func projectMessageEditSession() {
        messageEditSession = selectedChatID.flatMap { messageEditSessions[$0] }.flatMap {
            $0.contextID == conversationGeneration && $0.source.accountID == draftAccountID ? $0 : nil
        }
        refreshCustomEmojiDescriptors()
    }

    @discardableResult
    public func beginMessageEdit(source: TelegramMessageActionSource, author: String, contextID: UUID) -> Bool {
        guard messageSelection.session == nil, contextID == conversationGeneration, phase == .ready, !isBusy, !isForwardComposerLocked,
            composerDraftRecoveryError == nil, serverDraftConflict == nil, !isResolvingServerDraft,
            !isRestoringPendingUpload, pendingUploadRecoveryError == nil, upload.phase == .idle,
            !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
            source.accountID == draftAccountID, source.chatID == selectedChatID,
            knownChats[source.chatID] != nil, source.canEdit, !source.fingerprint.isEmpty,
            source.peerID == source.chatID || source.metadata.migrationChatID == source.chatID,
            source.metadata.formattedText?.isEditable != false,
            let formatted = messageFormattedEditDraft(for: source), formatted.isEditable,
            let input = try? TelegramComposerInput(formattedText: formatted)
        else { return false }
        if let current = messageEditSessions[source.chatID], current.source == source,
            current.contextID == contextID
        {
            projectMessageEditSession()
            return true
        }
        messageEditSessions[source.chatID] = TelegramMessageEditSession(
            source: source, author: author,
            contextID: contextID, input: input)
        projectMessageEditSession()
        return true
    }

    @discardableResult
    public func updateMessageEditInput(_ input: TelegramComposerInput, sessionID: UUID, contextID: UUID) -> Bool {
        guard phase == .ready, contextID == conversationGeneration, let current = messageEditSession,
            current.id == sessionID, current.contextID == contextID,
            current.source.accountID == draftAccountID, current.source.chatID == selectedChatID,
            input.formattedText.isEditable
        else { return false }
        guard current.input != input else { return true }
        messageEditSessions[current.source.chatID] = TelegramMessageEditSession(
            id: current.id,
            source: current.source, author: current.author, contextID: contextID, input: input,
            captionAboveMedia: current.captionAboveMedia)
        editDrafts[EditDraftKey(current.source)] = input.formattedText
        projectMessageEditSession()
        return true
    }

    @discardableResult
    public func updateMessageEditCaptionPlacement(_ above: Bool, sessionID: UUID, revision: UUID, contextID: UUID) -> Bool {
        guard phase == .ready, !isBusy, contextID == conversationGeneration,
            messageSelection.session == nil, !isForwardComposerLocked, composerDraftRecoveryError == nil, serverDraftConflict == nil,
            !isResolvingServerDraft,
            !isRestoringPendingUpload, pendingUploadRecoveryError == nil, upload.phase == .idle,
            !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
            let current = messageEditSession, current.id == sessionID, current.revision == revision,
            current.contextID == contextID, current.source.accountID == draftAccountID,
            current.source.chatID == selectedChatID, current.source.canEdit, current.source.metadata.hasMedia
        else { return false }
        guard current.captionAboveMedia != above else { return true }
        messageEditSessions[current.source.chatID] = TelegramMessageEditSession(
            id: current.id,
            source: current.source, author: current.author, contextID: contextID,
            input: current.input, captionAboveMedia: above)
        projectMessageEditSession()
        return true
    }

    @discardableResult
    public func submitMessageEdit(sessionID: UUID, revision: UUID, contextID: UUID) -> Bool {
        guard let current = messageEditSession, current.id == sessionID, current.revision == revision,
            current.contextID == contextID, current.canSubmit
        else { return false }
        return performMessageAction(current.action, source: current.source, contextID: contextID)
    }

    @discardableResult
    public func cancelMessageEdit(sessionID: UUID, contextID: UUID) -> Bool {
        guard contextID == conversationGeneration, let current = messageEditSession,
            current.id == sessionID, current.contextID == contextID,
            current.source.chatID == selectedChatID
        else { return false }
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
            let value = try? TelegramFormattedText(text: text)
        else { return }
        saveMessageFormattedEditDraft(value, source: source, contextID: contextID)
    }

    public func saveMessageFormattedEditDraft(_ value: TelegramFormattedText, source: TelegramMessageActionSource, contextID: UUID) {
        guard contextID == conversationGeneration, source.accountID == draftAccountID else { return }
        editDrafts[EditDraftKey(source)] = value
    }

    public func actionSource(for message: TelegramMessage) -> TelegramMessageActionSource? {
        guard phase == .ready, let accountID = draftAccountID, let chatID = selectedChatID,
            knownChats[chatID] != nil, let metadata = message.actionMetadata
        else { return nil }
        return TelegramMessageActionSource(metadata: metadata, accountID: accountID, chatID: chatID)
    }

    @discardableResult
    public func performMessageAction(_ action: TelegramMessageAction, source: TelegramMessageActionSource, contextID: UUID) -> Bool {
        guard messageSelection.session == nil, !isRestoringPendingUpload, composerDraftRecoveryError == nil, serverDraftConflict == nil,
            !isResolvingServerDraft,
            !isForwardComposerLocked, pendingUploadRecoveryError == nil,
            contextID == conversationGeneration, phase == .ready, !isBusy, upload.phase == .idle,
            !messageActions.isBusy, messageActions.phase != .uncertain, !selectedMessagesDeletionBlocksActions,
            source.accountID == draftAccountID, source.chatID == selectedChatID,
            knownChats[source.chatID] != nil
        else { return false }
        if case let .forward(destination) = action {
            guard let chat = forwardDestinations.first(where: { $0.id == destination }) else { return false }
            knownChats[destination] = chat
        }
        replyComposerSubmission = nil
        if let formatted = replyText(action) {
            guard composerForwardIntent == nil else { return false }
            if let target = drafts.snapshot(accountID: source.accountID, chatID: source.chatID, threadID: selectedThreadID)?.replyTarget {
                guard target == TelegramComposerReplyTarget(source: source), composerReply.resolved?.source == source else { return false }
            }
            if let snapshot = composerSubmission(formatted: formatted, accountID: source.accountID, chatID: source.chatID) {
                replyComposerSubmission = (source, snapshot)
            }
        }
        submittedEditSession = nil
        if let edited = TelegramMessageEditContent(action: action, source: source),
            let session = messageEditSession, session.source == source, session.contextID == contextID
        {
            guard session.input.formattedText == edited.formatted,
                session.captionAboveMedia == edited.captionAboveMedia
            else { return false }
            submittedEditSession = session
        }
        // Capture before perform: providers may synchronously acknowledge.
        let accepted = messageActions.perform(action, source: source)
        if !accepted {
            replyComposerSubmission = nil
            submittedEditSession = nil
        }
        return accepted
    }
}
