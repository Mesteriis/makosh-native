import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Attachment preparation targets and composer hand-off during uploads.
extension TelegramModel {
    public var uploadTarget: TelegramUploadTarget? {
        guard phase == .ready, !isBusy, !selectedMessagesDeletionBlocksActions, composerDraftRecoveryError == nil,
            serverDraftConflict == nil, !isResolvingServerDraft,
            composerForwardIntent == nil, let chat = selectedChat, let accountID = draftAccountID
        else { return nil }
        if !isSyntheticPreview {
            guard
                [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel]
                    .contains(PeerId(chat.id).namespace) || (telegramSecretPeerID(chat.id) != nil && composerSupportsAttachments)
            else { return nil }
        }
        return TelegramUploadTarget(accountID: accountID, chatID: chat.id, title: chat.title, selectedThreadID: selectedThreadID)
    }

    public func prepareUpload(
        source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, caption: String, contextID: UUID,
        photoSize: TelegramUploadPhotoSize = .standard
    ) {
        guard let input = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: caption)) else { return }
        prepareUpload(source: source, mode: mode, target: target, captionInput: input, contextID: contextID, photoSize: photoSize)
    }

    public func prepareUpload(
        source: URL, mode: TelegramUploadMode, target: TelegramUploadTarget, captionInput: TelegramComposerInput, contextID: UUID,
        photoSize: TelegramUploadPhotoSize = .standard
    ) {
        guard canPrepareUpload(target: target, contextID: contextID) else { return }
        upload.prepare(
            sources: [.init(source: source, mode: mode)], isGrouped: false, target: target, captionInput: captionInput,
            photoSize: photoSize, captionPolicy: try? .init(maximumUTF16Count: uploadCaptionMaximumUTF16Count))
    }

    public func prepareUpload(
        sources: [TelegramUploadSelection], isGrouped: Bool, target: TelegramUploadTarget,
        captionInput: TelegramComposerInput, contextID: UUID, photoSize: TelegramUploadPhotoSize = .standard
    ) {
        guard canPrepareUpload(target: target, contextID: contextID) else { return }
        upload.prepare(
            sources: sources, isGrouped: isGrouped, target: target, captionInput: captionInput, photoSize: photoSize,
            captionPolicy: try? .init(maximumUTF16Count: uploadCaptionMaximumUTF16Count))
    }

    public func uploadTarget(replyTo source: TelegramMessageActionSource?, contextID: UUID) -> TelegramUploadTarget? {
        guard !isRestoringPendingUpload, pendingUploadRecoveryError == nil, contextID == conversationGeneration,
            composerSupportsAttachments, let target = uploadTarget
        else { return nil }
        if let replyTarget = drafts.snapshot(accountID: target.accountID, chatID: target.chatID, threadID: target.selectedThreadID)?
            .replyTarget
        {
            guard let source, TelegramComposerReplyTarget(source: source) == replyTarget,
                composerReply.resolved?.source == source
            else { return nil }
        }
        let captured = TelegramUploadTarget(
            accountID: target.accountID, chatID: target.chatID,
            title: target.title, replySource: source, selectedThreadID: target.selectedThreadID)
        return captured.hasValidReplySource ? captured : nil
    }

    func suspendUploadComposer(target: TelegramUploadTarget, input: TelegramComposerInput, id: UUID) {
        uploadComposerPreparationID = id
        uploadComposerTransfer = nil
        uploadComposerSubmission = nil
        guard target.accountID == draftAccountID,
            let snapshot = drafts.snapshot(accountID: target.accountID, chatID: target.chatID, threadID: target.selectedThreadID),
            snapshot.input == input,
            snapshot.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:))
        else { return }
        uploadComposerTransfer = (id, snapshot)
        if selectedChatID == target.chatID {
            displayComposerInput(.empty)
            refreshComposerReply()
        }
    }

    func finishUploadComposer(id: UUID) {
        guard uploadComposerPreparationID == id else { return }
        uploadComposerPreparationID = nil
        let transfer = uploadComposerTransfer
        uploadComposerTransfer = nil
        uploadComposerSubmission = nil
        guard let transfer, transfer.draft.accountID == draftAccountID, transfer.draft.chatID == selectedChatID,
            transfer.draft.threadID == selectedThreadID
        else { return }
        displayComposerInput(
            drafts.snapshot(accountID: transfer.draft.accountID, chatID: transfer.draft.chatID, threadID: transfer.draft.threadID)?.input
                ?? .empty)
        refreshComposerReply()
    }

    func captureUploadDraft(target: TelegramUploadTarget, caption: String) {
        guard let formatted = try? TelegramFormattedText(text: caption) else { return }
        captureUploadDraft(target: target, caption: formatted)
    }

    func captureUploadDraft(target: TelegramUploadTarget, caption: TelegramFormattedText) {
        uploadComposerSubmission = nil
        guard target.accountID == draftAccountID else { return }
        if uploadComposerPreparationID != nil {
            guard let transfer = uploadComposerTransfer, transfer.draft.accountID == target.accountID,
                transfer.draft.chatID == target.chatID,
                transfer.draft.threadID == target.selectedThreadID,
                transfer.draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:))
            else { return }
            uploadComposerSubmission = (transfer.draft, caption)
            return
        }
        guard let snapshot = drafts.snapshot(accountID: target.accountID, chatID: target.chatID, threadID: target.selectedThreadID),
            snapshot.input.formattedText == caption,
            snapshot.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:))
        else { return }
        uploadComposerSubmission = (snapshot, caption)
    }

    func acknowledgeUpload(target: TelegramUploadTarget, caption: String) {
        guard let formatted = try? TelegramFormattedText(text: caption) else { return }
        acknowledgeUpload(target: target, caption: formatted)
    }

    func acknowledgeUpload(target: TelegramUploadTarget, caption: TelegramFormattedText) {
        guard target.accountID == draftAccountID, let submitted = uploadComposerSubmission,
            submitted.draft.accountID == target.accountID, submitted.draft.chatID == target.chatID,
            submitted.draft.threadID == target.selectedThreadID,
            submitted.caption == caption
        else { return }
        uploadComposerSubmission = nil
        acknowledgeComposerDraft(formatted: submitted.draft.input.formattedText, submitted: submitted.draft)
    }
}
