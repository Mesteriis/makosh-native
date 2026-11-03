import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Multi-message selection, range resolution, copy and deletion.
extension TelegramModel {
    public var selectedMessagesDeletionBlocksActions: Bool { selectedMessagesDelete.isBusy || selectedMessagesDelete.phase == .uncertain }

    var canChangeMessageSelection: Bool {
        phase == .ready && !isBusy && !historyPage.isLoading && !historyPage.timedOut && !search.hasMessageQuery
            && !isRestoringComposerDraft && composerDraftRecoveryError == nil && serverDraftConflict == nil && !isResolvingServerDraft
            && !isForwardComposerLocked && !isRestoringPendingUpload && pendingUploadRecoveryError == nil && upload.phase == .idle
            && !messageActions.isBusy && messageActions.phase != .uncertain && !selectedMessagesDeletionBlocksActions
    }

    @discardableResult
    public func toggleMessageGroupSelection(
        group: TelegramHistoryItem, sessionID: UUID?, expectedRevision: UUID?,
        contextID: UUID, windowID: UUID, extendingRange: Bool = false
    ) -> Bool {
        guard canChangeMessageSelection, contextID == conversationGeneration, historyWindowID == windowID,
            group.isAlbum, let current = historyItems.first(where: { $0.id == group.id }), current == group,
            zip(current.messages, group.messages).allSatisfy({ fresh, frozen in
                fresh.text.utf8.elementsEqual(frozen.text.utf8)
                    && fresh.actionMetadata?.fingerprint.utf8.elementsEqual(frozen.actionMetadata?.fingerprint.utf8 ?? "".utf8) == true
            })
        else { return false }
        let sources = current.messages.compactMap { actionSource(for: $0) }
        guard sources.count == current.messages.count else { return false }
        if let sessionID, let expectedRevision {
            guard messageSelection.session?.id == sessionID, messageSelection.session?.revision == expectedRevision else { return false }
            cancelMessageSelectionRange()
            selectedMessagesCopy.cancel()
            let changed = messageSelection.toggleGroup(
                sources: sources, sessionID: sessionID, contextID: contextID,
                expectedRevision: expectedRevision, extendingRange: extendingRange)
            if changed { resolveMessageSelectionRange(windowID: windowID) }
            return changed
        }
        guard sessionID == nil, expectedRevision == nil, messageSelection.session == nil else { return false }
        return messageSelection.beginGroup(sources: sources, contextID: contextID, extendingRange: extendingRange)
    }

    @discardableResult
    public func beginMessageSelection(messageID: String, contextID: UUID, windowID: UUID, extendingRange: Bool = false) -> Bool {
        guard canChangeMessageSelection, contextID == conversationGeneration, historyWindowID == windowID,
            messageSelection.session == nil, let message = messages.first(where: { $0.id == messageID }),
            let source = actionSource(for: message)
        else { return false }
        return messageSelection.begin(source: source, contextID: contextID, extendingRange: extendingRange)
    }

    @discardableResult
    public func toggleMessageSelection(
        messageID: String, sessionID: UUID, contextID: UUID, windowID: UUID, extendingRange: Bool = false
    ) -> Bool {
        guard canChangeMessageSelection, contextID == conversationGeneration, historyWindowID == windowID,
            messageSelection.session?.id == sessionID,
            let message = messages.first(where: { $0.id == messageID }), let source = actionSource(for: message)
        else { return false }
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

    func cancelMessageSelectionRange() {
        messageSelection.cancelRange()
        selectionRangeDeadline?.cancel()
        selectionRangeDeadline = nil
        selectionRangeDisposable.set(nil)
    }

    func resolveMessageSelectionRange(windowID: UUID) {
        guard let request = messageSelection.rangeRequest else { return }
        guard let provider = selectionRangeProvider, provider.accountID == request.accountID else {
            messageSelection.failRange(request: request)
            return
        }
        selectionRangeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.messageSelection.rangeRequest == request else { return }
            self.messageSelection.failRange(request: request)
            self.cancelMessageSelectionRange()
        }
        let lease = provider.resolve(request: request) { [weak self] sources in
            guard let self, self.messageSelection.rangeRequest == request else { return }
            guard self.canChangeMessageSelection, self.conversationGeneration == request.contextID,
                self.draftAccountID == request.accountID, self.selectedChatID == request.chatID,
                self.historyWindowID == windowID
            else {
                self.cancelMessageSelectionRange()
                return
            }
            _ = self.messageSelection.applyRange(sources: sources, request: request)
            self.cancelMessageSelectionRange()
        }
        // A provider may finish synchronously before returning its disposable.
        if messageSelection.rangeRequest == request { selectionRangeDisposable.set(lease) } else { lease.dispose() }
    }

    public func cancelMessageSelection(sessionID: UUID, contextID: UUID) {
        guard contextID == conversationGeneration, messageSelection.session?.id == sessionID else { return }
        guard !selectedMessagesDeletionBlocksActions else { return }
        cancelMessageSelectionRange()
        selectedMessagesCopy.cancel()
        messageSelection.cancel()
    }

    func currentMessageSelection(sessionID: UUID, contextID: UUID, revision: UUID) -> TelegramMessageSelectionSession? {
        guard phase == .ready, contextID == conversationGeneration, let session = messageSelection.session,
            session.id == sessionID, session.revision == revision, session.contextID == contextID,
            session.accountID == draftAccountID, session.chatID == selectedChatID
        else { return nil }
        return session
    }

    @discardableResult
    public func copySelectedMessages(
        sessionID: UUID, contextID: UUID, expectedRevision: UUID,
        receive: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard canChangeMessageSelection, !messageSelection.isResolvingRange,
            let session = currentMessageSelection(sessionID: sessionID, contextID: contextID, revision: expectedRevision),
            session.canCopy
        else { return false }
        return selectedMessagesCopy.start(
            request: .init(session: session),
            isCurrent: { [weak self] in
                guard let self, !self.selectedMessagesDeletionBlocksActions else { return false }
                return self.currentMessageSelection(sessionID: sessionID, contextID: contextID, revision: expectedRevision)?.canCopy == true
            }, receive: receive)
    }

    @discardableResult
    public func deleteSelectedMessages(forEveryone: Bool, sessionID: UUID, contextID: UUID, expectedRevision: UUID) -> Bool {
        guard canChangeMessageSelection, !selectedMessagesCopy.isBusy, !messageSelection.isResolvingRange,
            let session = currentMessageSelection(sessionID: sessionID, contextID: contextID, revision: expectedRevision),
            forEveryone ? session.canDeleteForEveryone : session.canDeleteLocally
        else { return false }
        selectedDeleteEditSession = messageEditSessions[session.chatID]
        return selectedMessagesDelete.perform(request: .init(session: session, forEveryone: forEveryone))
    }
}
