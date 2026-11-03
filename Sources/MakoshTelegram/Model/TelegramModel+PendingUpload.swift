import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Recovery of prepared uploads that survived a restart.
extension TelegramModel {
    func bindPendingUploadRecovery(_ store: (any TelegramUploadRecoveryStore)?, replyProvider: (any TelegramComposerReplyProvider)?) {
        cancelPendingRecovery()
        pendingRecoveryAttempt = nil
        pendingRecoveryStore = store
        pendingReplyProvider = replyProvider
        restorePendingUpload()
    }

    func cancelPendingRecovery() {
        pendingRecoveryID = UUID()
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = nil
        pendingRecoveryDeadline?.cancel()
        pendingRecoveryDeadline = nil
        isRestoringPendingUpload = false
        pendingUploadRecoveryError = nil
    }

    public func retryPendingUploadRecovery() {
        cancelPendingRecovery()
        pendingRecoveryAttempt = nil
        restorePendingUpload()
    }

    func restorePendingUpload() {
        guard composerDraftLoadID == nil, !isRestoringPendingUpload,
            let accountID = draftAccountID, let chatID = selectedChatID,
            let store = pendingRecoveryStore, store.accountID == accountID,
            upload.phase == .idle,
            pendingRecoveryAttempt?.account != accountID || pendingRecoveryAttempt?.chat != chatID
        else { return }
        pendingRecoveryAttempt = (accountID, chatID)
        let request = UUID(), context = conversationGeneration, threadID = selectedThreadID, restorationEpoch = upload.recoveryRestoreEpoch
        pendingRecoveryID = request
        isRestoringPendingUpload = true
        pendingUploadRecoveryError = nil
        pendingRecoveryDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.pendingRecoveryID == request, self.isRestoringPendingUpload else { return }
            self.cancelPendingRecovery()
            self.pendingUploadRecoveryError = "Не удалось открыть подготовленное вложение. Повторите восстановление."
        }
        pendingRecoveryTask = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool {
                !Task.isCancelled && self.pendingRecoveryID == request && self.conversationGeneration == context
                    && self.draftAccountID == accountID && self.selectedChatID == chatID && self.selectedThreadID == threadID
            }
            defer {
                if self.pendingRecoveryID == request {
                    self.pendingRecoveryTask = nil
                    self.pendingRecoveryDeadline?.cancel()
                    self.pendingRecoveryDeadline = nil
                    self.isRestoringPendingUpload = false
                }
            }
            do {
                guard let draft = try await store.load(chatID: chatID), current() else { return }
                guard draft.isValid, draft.accountID == accountID, draft.chatID == chatID else { throw TelegramUploadFileError.unavailable }
                guard draft.threadID == threadID else { return }
                switch draft.disposition {
                case .cancelled: return
                case .accepted, .acceptedBatch:
                    if let original = draft.originalDraft {
                        self.acknowledgeComposerDraft(formatted: original.input.formattedText, submitted: original)
                    }
                    return
                case .prepared, .submissionStarted: break
                }
                var source: TelegramMessageActionSource?
                if let target = draft.replyTarget {
                    source = await self.resolvePendingReply(target, chatID: chatID, accountID: accountID)
                    guard current() else { return }
                    if source == nil, draft.disposition == .prepared { throw TelegramUploadFileError.unavailable }
                }
                let bundle = try await store.restoreBundle(draft: draft)
                guard current() else {
                    try? await bundle.discardInBackground()
                    return
                }
                let target = TelegramUploadTarget(
                    accountID: accountID, chatID: chatID, title: draft.title, replySource: source, selectedThreadID: draft.threadID)
                guard
                    await self.upload.restore(
                        draft: draft, bundle: bundle, target: target,
                        restorationEpoch: restorationEpoch, admission: current)
                else {
                    try? await bundle.discardInBackground()
                    if current() { throw TelegramUploadFileError.unavailable }
                    return
                }
                // Ownership is now in the controller. A later context change
                // may already have cancelled it; this caller must not discard it.
                guard current() else { return }
            } catch {
                if current() {
                    self.pendingUploadRecoveryError =
                        "Не удалось восстановить подготовленное вложение. Черновик сохранён. Повторите восстановление."
                }
            }
        }
    }

    func resolvePendingReply(_ target: TelegramComposerReplyTarget, chatID: Int64, accountID: Int64) async -> TelegramMessageActionSource? {
        guard let provider = pendingReplyProvider, provider.accountID == accountID else { return nil }
        return await withCheckedContinuation { continuation in
            let disposable = MetaDisposable()
            var completed = false
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard !completed else { return }
                completed = true
                disposable.dispose()
                continuation.resume(returning: nil)
            }
            disposable.set(
                provider.resolve(target: target, chatID: chatID) { value in
                    guard !completed else { return }
                    completed = true
                    timeout.cancel()
                    disposable.dispose()
                    guard let source = value?.source, source.accountID == accountID, source.chatID == chatID,
                        source.canReply, !source.fingerprint.isEmpty, TelegramComposerReplyTarget(source: source) == target,
                        source.peerID == chatID || source.metadata.migrationChatID == chatID
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: source)
                })
        }
    }
}
