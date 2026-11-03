import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Custom emoji descriptor resolution and guarded composer insertion.
extension TelegramModel {
    @discardableResult public func requestCustomEmojiInsertion(
        descriptor: TelegramCustomEmojiDescriptor,
        catalogContextID: UUID, expectedInput: TelegramComposerInput, contextID: UUID,
        chatID: Int64, expectedRevision: UUID?
    ) -> Bool {
        guard phase == .ready, !isBusy, composerSupportsCustomEmoji, !isComposerSuspended, !isRestoringComposerDraft,
            !isRestoringPendingUpload, !isForwardComposerLocked, !isResolvingServerDraft,
            !voiceRecording.isActive, upload.phase == .idle, serverDraftConflict == nil,
            composerDraftRecoveryError == nil, pendingUploadRecoveryError == nil,
            contextID == conversationGeneration, chatID == selectedChatID,
            let accountID = draftAccountID, customEmojiCatalog.snapshot?.accountID == accountID,
            catalogContextID == customEmojiCatalog.contextID,
            expectedInput == composerInput, expectedRevision == composerInputRevision,
            customEmojiCatalog.canInsert(descriptor, chatID: chatID)
        else { return false }
        let request = TelegramCustomEmojiInsertionRequest(
            descriptor: descriptor,
            expectedInput: expectedInput, contextID: contextID)
        pendingEmojiInsertion = (request, accountID, chatID, selectedThreadID, expectedRevision, catalogContextID)
        customEmojiInsertion = request
        return true
    }

    @discardableResult public func consumeCustomEmojiInsertion(id: UUID, expectedInput: TelegramComposerInput) -> Bool {
        guard let pending = pendingEmojiInsertion, pending.request.id == id,
            customEmojiInsertion == pending.request
        else { return false }
        pendingEmojiInsertion = nil
        customEmojiInsertion = nil
        return phase == .ready && !isBusy && composerSupportsCustomEmoji && !isComposerSuspended && !isForwardComposerLocked
            && !isRestoringComposerDraft && !isRestoringPendingUpload && !isResolvingServerDraft && serverDraftConflict == nil
            && !voiceRecording.isActive && upload.phase == .idle && pending.request.contextID == conversationGeneration
            && pending.account == draftAccountID && pending.chat == selectedChatID && pending.thread == selectedThreadID
            && pending.revision == composerInputRevision && pending.catalog == customEmojiCatalog.contextID
            && expectedInput == composerInput && expectedInput == pending.request.expectedInput
            && customEmojiCatalog.snapshot?.accountID == pending.account
            && customEmojiCatalog.canInsert(pending.request.descriptor, chatID: pending.chat)
    }

    func refreshCustomEmojiDescriptors(
        uploadCaption: TelegramFormattedText? = nil,
        catalogItems: [TelegramCustomEmojiDescriptor]? = nil, topics: [TelegramForumTopic]? = nil
    ) {
        guard let context = customEmojiPlaybackContext, context.accountID == draftAccountID else { return }
        let catalog = customEmojiCatalog.snapshot
        let known =
            catalogItems
            ?? ((catalog?.recent ?? []) + (catalog?.installed.flatMap(\.items) ?? []) + (catalog?.featured.flatMap(\.items) ?? []))
        var ids = Set<Int64>()
        var values =
            messages.compactMap(\.formattedTextForDisplay) + [
                composerInput.formattedText, uploadCaption ?? upload.captionInput.formattedText,
            ]
        if let edit = messageEditSession { values.append(edit.input.formattedText) }
        for value in values {
            for entity in value.entities {
                if case let .customEmoji(_, fileID) = entity.kind { ids.insert(fileID) }
            }
        }
        for topic in topics ?? forumTopics.snapshot?.topics ?? [] { if let icon = topic.iconFileID { ids.insert(icon) } }
        ids = Set(ids.sorted().prefix(1024))
        var available: [Int64: TelegramCustomEmojiDescriptor] = [:]
        for descriptor in known.prefix(1024) { available[descriptor.fileID] = descriptor }
        for id in ids { if let value = customEmojiDescriptors[id] { available[id] = value } }
        customEmojiDescriptors = available
        guard ids != emojiRequested else { return }
        emojiRequested = ids
        emojiResolutionID = UUID()
        emojiResolution.set(nil)
        guard !ids.isEmpty else { return }
        let request = emojiResolutionID, accountID = context.accountID
        emojiResolution.set(
            context.resolveDescriptors(fileIDs: Array(ids)).start(next: { [weak self, weak context] values in
                MainActor.assumeIsolated {
                    guard let self, let context, context === self.customEmojiPlaybackContext,
                        self.draftAccountID == accountID, self.emojiResolutionID == request
                    else { return }
                    self.customEmojiDescriptors.merge(values, uniquingKeysWith: { _, new in new })
                }
            }))
    }
}
