import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Server draft observation and local/remote conflict resolution.
extension TelegramModel {
    func bindServerDraftObserver(_ observer: (any TelegramServerDraftObserving)?) {
        serverDraftObserver = observer
        refreshServerDraftObservation()
    }

    func refreshServerDraftObservation() {
        serverDraftResolutionDeadline?.cancel()
        serverDraftResolutionDeadline = nil
        serverDraftObservation.set(nil)
        serverDraftResolution.set(nil)
        serverDraftResolutionID = nil
        isResolvingServerDraft = false
        nextServerDraftUpdate = nil
        serverDraftConflict = nil
        serverDraftContext = nil
        guard let accountID = draftAccountID, let chatID = selectedChatID,
            let observer = serverDraftObserver, observer.accountID == accountID,
            let resolver = composerDraftRepository as? any TelegramServerDraftResolving, resolver.accountID == accountID
        else { return }
        let context = TelegramServerDraftObservationContext(
            accountID: accountID, chatID: chatID, threadID: selectedThreadID, generation: UUID())
        serverDraftContext = context
        let subscription = observer.observe(chatID: chatID, context: context) { [weak self] event in
            guard let self, self.serverDraftContext == event.context,
                self.draftAccountID == event.context.accountID, self.selectedChatID == event.context.chatID,
                self.selectedThreadID == event.context.threadID
            else { return }
            switch event.result {
            case let .success(update): self.receiveServerDraftUpdate(update, context: event.context)
            case let .failure(error):
                self.composerDraftRecoveryError = error.localizedDescription
                self.error = error.localizedDescription
            }
        }
        if serverDraftContext == context { serverDraftObservation.set(subscription) } else { subscription.dispose() }
    }

    func receiveServerDraftUpdate(_ update: TelegramServerDraftUpdate, context: TelegramServerDraftObservationContext) {
        guard update.draft.isValid, update.draft.accountID == context.accountID, update.draft.chatID == context.chatID,
            update.draft.threadID == context.threadID,
            serverDraftContext == context
        else { return }
        if isResolvingServerDraft || isRestoringComposerDraft {
            nextServerDraftUpdate = update
            return
        }
        let current = drafts.snapshot(accountID: context.accountID, chatID: context.chatID, threadID: context.threadID)
        let clean =
            current?.revision == update.basisRevision
            && unsavedComposerDrafts[ComposerDraftKey(accountID: context.accountID, chatID: context.chatID, threadID: context.threadID)]
                == nil
            && current?.forwardIntent == nil && !isComposerSuspended && !voiceRecording.isActive && messageEditSession == nil
            && !isRestoringComposerDraft
        if clean {
            beginServerDraftResolution(update, context: context, choice: .remote)
        } else {
            serverDraftConflict = .init(
                id: UUID(), localText: current?.text ?? "", remoteText: update.draft.text,
                update: update, context: context)
        }
    }

    public func resolveServerDraftConflict(id: UUID, keepLocal: Bool) {
        guard let conflict = serverDraftConflict, conflict.id == id else { return }
        beginServerDraftResolution(conflict.update, context: conflict.context, choice: keepLocal ? .local : .remote)
    }

    func beginServerDraftResolution(
        _ update: TelegramServerDraftUpdate, context: TelegramServerDraftObservationContext,
        choice: TelegramServerDraftChoice
    ) {
        guard serverDraftContext == context, selectedChatID == context.chatID, selectedThreadID == context.threadID,
            draftAccountID == context.accountID,
            !isResolvingServerDraft, !isComposerSuspended, !voiceRecording.isActive, messageEditSession == nil,
            let resolver = composerDraftRepository as? any TelegramServerDraftResolving,
            resolver.accountID == context.accountID
        else { return }
        let local = drafts.snapshot(accountID: context.accountID, chatID: context.chatID, threadID: context.threadID)
        guard local?.forwardIntent == nil else { return }
        let requestID = UUID(), revision = local?.revision
        serverDraftResolutionID = requestID
        isResolvingServerDraft = true
        serverDraftResolutionDeadline?.cancel()
        serverDraftResolutionDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.serverDraftResolutionID == requestID, self.serverDraftContext == context else { return }
            self.serverDraftResolutionID = nil
            self.isResolvingServerDraft = false
            self.serverDraftResolution.set(nil)
            self.serverDraftResolutionDeadline = nil
            let candidate = self.nextServerDraftUpdate ?? update
            self.nextServerDraftUpdate = nil
            self.serverDraftConflict = .init(
                id: UUID(), localText: local?.text ?? "", remoteText: candidate.draft.text,
                update: candidate, context: context)
            self.error = "Не получено подтверждение сохранения черновика. Текущий текст сохранён в поле ввода."
        }
        let operation = resolver.resolve(update: update, local: local, choice: choice) { [weak self] result in
            guard let self, self.serverDraftContext == context, self.serverDraftResolutionID == requestID,
                self.draftAccountID == context.accountID, self.selectedChatID == context.chatID, self.selectedThreadID == context.threadID
            else { return }
            self.serverDraftResolutionID = nil
            self.isResolvingServerDraft = false
            self.serverDraftResolutionDeadline?.cancel()
            self.serverDraftResolutionDeadline = nil
            switch result {
            case let .success(snapshot):
                guard
                    self.drafts.restore(
                        snapshot, accountID: context.accountID, chatID: context.chatID, threadID: context.threadID,
                        expectedRevision: revision)
                else {
                    self.refreshServerDraftObservation()
                    return
                }
                let key = ComposerDraftKey(accountID: context.accountID, chatID: context.chatID, threadID: context.threadID)
                if self.unsavedComposerDrafts[key]?.revision == revision { self.unsavedComposerDrafts[key] = nil }
                self.serverDraftConflict = nil
                self.composerDraftRecoveryError = nil
                self.displayComposerInput(snapshot.input)
                self.refreshComposerReply()
                self.refreshComposerForward()
            case let .failure(error):
                self.error = error.localizedDescription
                if error == .serverConflict {
                    self.refreshServerDraftObservation()
                    return
                }
                self.serverDraftConflict = .init(
                    id: UUID(), localText: local?.text ?? "", remoteText: update.draft.text,
                    update: update, context: context)
            }
            if let next = self.nextServerDraftUpdate {
                self.nextServerDraftUpdate = nil
                self.receiveServerDraftUpdate(next, context: context)
            }
        }
        if serverDraftResolutionID == requestID { serverDraftResolution.set(operation) } else { operation.dispose() }
    }
}
