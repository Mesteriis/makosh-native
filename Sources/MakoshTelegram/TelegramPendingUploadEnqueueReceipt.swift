import Foundation
import Postbox
import TelegramCore

/// Immutable admission/receipt capability. Invoke validate before the native
/// addMessages operation and acknowledge inside that very same transaction.
internal struct TelegramPendingUploadEnqueueReceipt: Sendable {
    let preparationID: UUID
    let target: TelegramUploadTarget
    let file: TelegramUploadFile
    let mediaSpoiler: Bool
    let captionAboveMedia: Bool
    let caption: TelegramFormattedText
    let localResourceID: Int64?
    let videoThumbnail: TelegramUploadVideoThumbnailResource?
    init(preparationID: UUID, target: TelegramUploadTarget, file: TelegramUploadFile, caption: TelegramFormattedText, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false, localResourceID: Int64? = nil, videoThumbnail: TelegramUploadVideoThumbnailResource? = nil) {
        self.captionAboveMedia = captionAboveMedia; self.mediaSpoiler = mediaSpoiler
        self.preparationID = preparationID; self.target = target; self.file = file; self.caption = caption
        self.localResourceID = localResourceID
        self.videoThumbnail = videoThumbnail
    }
    nonisolated func validate(transaction: Transaction) -> Bool { current(transaction: transaction) != nil }
    private nonisolated func current(transaction: Transaction) -> TelegramPendingUploadDraft? {
        guard target.hasValidReplySource,
              file.mode == .video ? localResourceID != nil && telegramUploadVideoAttributes(file) != nil &&
                  videoThumbnail?.isValid == true && videoThumbnail?.id != localResourceID : videoThumbnail == nil,
              case let .success(value) = telegramPendingUploadRead(transaction: transaction, accountID: target.accountID, chatID: target.chatID),
              let draft = value, draft.id == preparationID, draft.disposition == .submissionStarted,
              draft.captionInput.formattedText == caption,
              draft.captionAboveMedia == captionAboveMedia,
              draft.mediaSpoiler == mediaSpoiler,
              draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)),
              draft.file.attachment.name.utf8.elementsEqual(file.name.utf8),
              draft.file.plaintextByteCount == file.size, draft.file.attachment.size == file.size,
              draft.file.attachment.kind == file.mode.rawValue, draft.video == file.video else { return nil }
        return draft
    }
    nonisolated func acknowledge(transaction: Transaction, messageIDs: [MessageId?]) -> Bool {
        guard let draft = current(transaction: transaction), messageIDs.count == 1, let id = messageIDs[0],
              id.peerId.toInt64() == target.chatID, id.namespace == Namespaces.Message.Local,
              let queued = transaction.getMessage(id), !queued.flags.contains(.Incoming),
              queued.text.utf8.elementsEqual(caption.text.utf8) else { return false }
        let entityAttributes = queued.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }
        let placementCount = queued.attributes.filter { $0 is InvertMediaMessageAttribute }.count
        let spoilerCount = queued.attributes.filter { $0 is MediaSpoilerMessageAttribute }.count
        guard entityAttributes.count <= 1,
              placementCount == (captionAboveMedia ? 1 : 0),
              spoilerCount == (mediaSpoiler ? 1 : 0),
              (entityAttributes.first?.entities ?? []) == caption.engineEntities() else { return false }
        if file.mode == .video {
            guard let localResourceID, let videoThumbnail, let expected = telegramUploadVideoAttributes(file), queued.media.count == 1,
                  let native = queued.media.first as? TelegramMediaFile,
                  let resource = native.resource as? LocalFileMediaResource,
                  resource.fileId == localResourceID, resource.size == file.size, !resource.isSecretRelated,
                  native.fileId == MediaId(namespace: Namespaces.Media.LocalFile, id: localResourceID),
                  native.mimeType == "video/mp4", native.size == file.size, native.attributes == expected,
                  native.partialReference == nil, native.videoCover == nil,
                  native.previewRepresentations.count == 1, videoThumbnail.matches(native.previewRepresentations[0]),
                  native.videoThumbnails.isEmpty, native.immediateThumbnailData == nil,
                  native.alternativeRepresentations.isEmpty, queued.groupingKey == nil else { return false }
        }
        let accepted = TelegramPendingUploadDraft(id: draft.id, revision: UUID(), accountID: draft.accountID,
            chatID: draft.chatID, title: draft.title, captionInput: draft.captionInput, captionAboveMedia: draft.captionAboveMedia, mediaSpoiler: draft.mediaSpoiler,
            originalDraft: draft.originalDraft, replyTarget: draft.replyTarget, file: draft.file, video: draft.video,
            disposition: .accepted(localMessageID: "\(id.peerId.toInt64()):\(id.namespace):\(id.id)"))
        if case .success = telegramPendingUploadWrite(transaction: transaction, accountID: draft.accountID,
            draft: accepted, expectedRevision: draft.revision) { return true }
        return false
    }
}
