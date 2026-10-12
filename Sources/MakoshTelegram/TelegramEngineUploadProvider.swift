import Foundation
import Darwin
import UniformTypeIdentifiers
import TelegramCore
import Postbox
import SwiftSignalKit

/// New local media has no remote message provenance or invented cloud credentials.
func telegramUploadMedia(_ file: TelegramUploadFile, videoThumbnail: TelegramUploadVideoThumbnailResource? = nil,
                         videoCover: TelegramUploadVideoThumbnailResource? = nil,
                         webPPreview: TelegramUploadVideoThumbnailResource? = nil,
                         gifPreview: TelegramUploadVideoThumbnailResource? = nil,
                         sourceFacts: TelegramUploadSourceFacts? = nil,
                         resourceID requestedResourceID: Int64? = nil) -> (LocalFileMediaResource, AnyMediaReference)? {
    guard (try? TelegramUploadFileIO.validateMetadata(file)) != nil else { return nil }
    guard sourceFacts?.isValid ?? true else { return nil }
    guard file.mode == .video || (file.video == nil && file.videoCover == nil),
          (file.videoCover == nil) == (videoCover == nil) else { return nil }
    if let staged = file.videoCover {
        guard videoCover?.width == staged.width, videoCover?.height == staged.height, videoCover?.size == staged.size else { return nil }
    }
    if file.metadata?.roundVideo != nil {
        guard videoThumbnail?.isValid ?? true else { return nil }
    } else {
        guard file.mode == .video && file.metadata?.gif == nil ? videoThumbnail?.isValid == true : videoThumbnail == nil else { return nil }
    }
    guard file.mode == .video ? videoCover?.isValid ?? true : videoCover == nil,
          videoCover == nil || videoCover?.id != videoThumbnail?.id else { return nil }
    if let webPPreview {
        guard file.mode == .file, case .webP = file.metadata, webPPreview.isValid,
              webPPreview.id != videoThumbnail?.id, webPPreview.id != videoCover?.id else { return nil }
    }
    if let gifPreview {
        guard file.metadata?.gif != nil, gifPreview.isValid, videoThumbnail == nil,
              videoCover == nil, webPPreview == nil else { return nil }
    }
    if let requestedResourceID, requestedResourceID == videoThumbnail?.id || requestedResourceID == videoCover?.id || requestedResourceID == webPPreview?.id || requestedResourceID == gifPreview?.id { return nil }
    var resourceID = requestedResourceID ?? Int64.random(in: Int64.min...Int64.max)
    while resourceID == videoThumbnail?.id || resourceID == videoCover?.id || resourceID == webPPreview?.id || resourceID == gifPreview?.id { resourceID = Int64.random(in: Int64.min...Int64.max) }
    let resource = LocalFileMediaResource(fileId: resourceID, size: file.size)
    let media: Media
    switch file.mode {
    case .video:
        guard let attributes = telegramUploadVideoAttributes(file) else { return nil }
        media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: resource.fileId),
            partialReference: nil, resource: resource, previewRepresentations: (gifPreview ?? videoThumbnail).map { [$0.representation] } ?? [], videoThumbnails: [],
            videoCover: videoCover.map { TelegramMediaImage(imageId: MediaId(namespace: 0, id: 0),
                representations: [$0.representation], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: []) },
            immediateThumbnailData: nil, mimeType: "video/mp4", size: file.metadata?.roundVideo == nil ? file.size : nil,
            attributes: attributes, alternativeRepresentations: [])
    case .file:
        if let facts = sourceFacts {
            guard facts.name.utf8.elementsEqual(file.name.utf8), facts.byteCount == file.size else { return nil }
        }
        var mime = sourceFacts?.selectionMIME ?? UTType(filenameExtension: URL(fileURLWithPath: file.name).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var attributes: [TelegramMediaFileAttribute] = []
        if file.metadata == nil, let facts = sourceFacts, case let .decoded(width, height) = facts.image {
            guard width >= 1, height >= 1, width <= Double(Int32.max), height <= Double(Int32.max) else { return nil }
            attributes.append(.ImageSize(size: PixelDimensions(width: Int32(width), height: Int32(height))))
        }
        if let voice = file.metadata?.voice {
            mime = "audio/ogg"
            attributes.append(.Audio(isVoice: true, duration: Int(voice.duration), title: nil, performer: nil, waveform: voice.waveform))
        }
        if case let .audio(audio) = file.metadata {
            if (try? TelegramUploadAudioIO.hasOggSignature(file)) == true { mime = "audio/ogg" }
            attributes.append(.Audio(isVoice: false, duration: Int(audio.duration), title: audio.title, performer: audio.performer, waveform: nil))
        }
        if case let .webP(webP) = file.metadata {
            mime = "image/webp"
            attributes.append(.ImageSize(size: PixelDimensions(width: webP.width, height: webP.height)))
        }
        if let gif = file.metadata?.gif {
            mime = "image/gif"
            attributes.append(.ImageSize(size: PixelDimensions(width: gif.width, height: gif.height)))
        }
        if file.metadata?.voice == nil { attributes.append(.FileName(fileName: telegramAttachmentName(file.name))) }
        if case .webP = file.metadata {
            attributes.append(.Sticker(displayText: "", packReference: nil, maskData: nil))
        }
        media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: resource.fileId),
            partialReference: nil, resource: resource, previewRepresentations: (gifPreview ?? webPPreview).map { [$0.representation] } ?? [], videoThumbnails: [],
            immediateThumbnailData: nil, mimeType: mime, size: file.metadata?.voice == nil ? file.size : nil,
            attributes: attributes, alternativeRepresentations: [])
    case .photo:
        guard let width = file.pixelWidth, let height = file.pixelHeight, width > 0, height > 0 else { return nil }
        let representation = TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: width, height: height),
            resource: resource, progressiveSizes: [], immediateThumbnailData: nil)
        media = TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: resource.fileId),
            representations: [representation], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    }
    return (resource, .standalone(media: media))
}

func telegramUploadVideoAttributes(_ file: TelegramUploadFile) -> [TelegramMediaFileAttribute]? {
    guard file.mode == .video, let video = file.video,
          video.isValid(name: file.name, size: file.size), file.pixelWidth == video.width,
          file.pixelHeight == video.height else { return nil }
    if let round = file.metadata?.roundVideo {
        return [.Video(duration: Double(round.nativeDuration), size: PixelDimensions(width: 200, height: 200),
            flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)]
    }
    if file.metadata?.gif != nil {
        var attributes: [TelegramMediaFileAttribute] = [.Video(duration: 0,
            size: PixelDimensions(width: video.width, height: video.height), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil)]
        if !video.inCollage { attributes.append(.Animated) }
        attributes.append(.FileName(fileName: telegramAttachmentName(file.name)))
        return attributes
    }
    var attributes: [TelegramMediaFileAttribute] = [
        .Video(duration: video.duration, size: PixelDimensions(width: video.width, height: video.height),
            flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil),
        .FileName(fileName: telegramAttachmentName((file.name as NSString).deletingPathExtension + ".mp4"))
    ]
    let mp4 = (file.name as NSString).pathExtension.lowercased() == "mp4"
    if !video.inCollage && !video.hasAudio && file.size < 10 * 1024 * 1024 && mp4 { attributes.append(.Animated) }
    if !mp4 { attributes.append(.hintFileIsLarge) }
    return attributes
}

@MainActor
final class TelegramEngineUploadProvider: TelegramUploadBatchProvider {
    private let account: Account
    private let approval: TelegramSendApprovalController
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account, approval: TelegramSendApprovalController) { self.account = account; self.approval = approval }

    func submit(bundle: TelegramRecoveredUploadBundle, draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        let account = self.account, approval = self.approval
        return TelegramUploadBatchSubmission(postbox: account.postbox, accountID: accountID, bundle: bundle, draft: draft,
            target: target, enqueue: { receipt, messages in
                receive(.awaitingApproval)
                return enqueueBatchUploadWithReceipt(account: account, approval: approval, receipt: receipt, messages: messages,
                    onApproved: { receive(.committing) })
            }, observe: { ids in observeBatchUpload(account: account, ids: ids) }, receive: receive)
    }

    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        let account = self.account, approval = self.approval
        return TelegramUploadBatchSubmission(postbox: account.postbox, accountID: accountID, items: items, draft: draft,
            target: target, enqueue: { receipt, messages in
                receive(.awaitingApproval)
                return enqueueBatchUploadWithReceipt(account: account, approval: approval, receipt: receipt, messages: messages,
                    onApproved: { receive(.committing) })
            }, observe: { ids in observeBatchUpload(account: account, ids: ids) }, receive: receive)
    }

    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        let lease = EngineUploadLease(receive: receive)
        let peerID = PeerId(target.chatID)
        guard target.accountID == accountID, target.hasValidReplySource, file.metadata == nil,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peerID.namespace),
              telegramFormattedCaptionCanSend(caption), (!captionAboveMedia && !mediaSpoiler) || file.mode != .file else {
            receive(.rejected); return lease
        }
        lease.preparation = TelegramUploadMediaBoxPreparation(mediaBox: account.postbox.mediaBox, file: file) { [weak lease, account, approval] result in
            guard let lease, !lease.stopped, !lease.validating, !lease.committing else { return }
            guard case let .success(prepared) = result else {
                lease.receive(.rejected); lease.stop(); return
            }
            let resource = prepared.resource, reference = prepared.reference
            lease.validating = true
            let commit: @MainActor (TelegramMessageActionSource?) -> Void = { [weak lease, account, approval] reply in
                guard let lease, !lease.stopped, !lease.committing else { return }
                guard let message = telegramUploadMessage(caption: caption, reference: reference, target: target, replySource: reply, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler) else {
                    lease.receive(.rejected); lease.stop(); return
                }
                lease.committing = true
                lease.receive(.committing)
                guard !lease.stopped else { return }
                let receipt = TelegramPendingUploadEnqueueReceipt(preparationID: preparationID,
                    target: target, file: file, caption: caption, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler,
                    localResourceID: resource.fileId, videoThumbnail: prepared.videoThumbnail, videoCover: prepared.videoCover)
                lease.receive(.awaitingApproval)
                guard !lease.stopped else { return }
                lease.enqueue.set((enqueueUploadWithReceipt(account: account, approval: approval, peerID: peerID,
                    message: message, receipt: receipt, onApproved: { [weak lease] in
                        guard let lease, !lease.stopped else { return }; lease.receive(.committing)
                    })
                |> deliverOnMainQueue).start(next: { [weak lease, account] admission in
                    guard let lease, !lease.stopped, !lease.accepted else { return }
                    let id: MessageId
                    switch admission {
                    case .rejected:
                        lease.receive(.rejected); lease.stop(); return
                    case .uncertain:
                        lease.receive(.uncertain); lease.stop(); return
                    case .accepted(let value): id = value
                    }
                    lease.accepted = true
                    lease.receive(.accepted("\(id.peerId.toInt64()):\(id.namespace):\(id.id)"))
                    guard !lease.stopped else { return }
                    lease.pending.set((account.pendingMessageManager.pendingMessageStatus(id)
                        |> deliverOnMainQueue).start(next: { [weak lease] status, failure in
                            guard let lease, !lease.stopped else { return }
                            if failure != nil { lease.receive(.queueFailed) }
                            else { lease.receive(.progress(status.map { Double($0.progress.progress) })) }
                            // nil or 100% is not server delivery/read acknowledgement.
                        }))
                }))
            }
            lease.captionValidation.set((telegramValidateOutgoingCaption(postbox: account.postbox, formatted: caption)
                |> deliverOnMainQueue).start(next: { [weak lease, account] valid in
                    guard let lease, !lease.stopped else { return }
                    guard valid else { lease.receive(.rejected); lease.stop(); return }
                    if let source = target.replySource {
                        lease.validation.set((validateTelegramReplySource(postbox: account.postbox, accountID: target.accountID, source: source)
                            |> deliverOnMainQueue).start(next: { fresh in commit(fresh) }))
                    } else { commit(nil) }
                }))
        }
        return lease
    }
}

@MainActor private func enqueueBatchUploadWithReceipt(account: Account, approval: TelegramSendApprovalController,
    receipt: TelegramUploadBatchEnqueueReceipt, messages: [EnqueueMessage],
    onApproved: @escaping @MainActor () -> Void) -> Signal<TelegramUploadBatchAdmission, NoError> {
    let context = TelegramSendContext(accountID: receipt.target.accountID, chatID: receipt.target.chatID,
        threadID: receipt.target.selectedThreadID, submissionRevision: receipt.draft.revision, messageCount: messages.count)
    let consent = telegramApprovalForDestination(account: account, approval: approval, context: context, title: receipt.target.title, onApproved: onApproved)
    return enqueueBatchUploadAfterApproval(account: account, receipt: receipt, context: context, messages: messages, approval: consent)
}
private nonisolated func enqueueBatchUploadAfterApproval(account: Account, receipt: TelegramUploadBatchEnqueueReceipt,
    context: TelegramSendContext, messages: [EnqueueMessage],
    approval: Signal<Result<TelegramPaidSendConsent?, TelegramSendApprovalError>, NoError>) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages,
        now: { Date().timeIntervalSince1970 + account.network.globalTimeDifference }) { messages, admission, commit in
        telegramEnqueueAfterApproval(account: account, context: context, messages: messages, approval: approval,
            specificAdmission: admission, specificCommit: commit) |> map { $0 ?? [nil] }
    }
}

private nonisolated func observeBatchUpload(account: Account, ids: [MessageId]) -> Signal<TelegramUploadBatchEvent, NoError> {
    let statuses = ids.map { account.pendingMessageManager.pendingMessageStatus($0) }
    return combineLatest(statuses) |> map { statuses in
        if statuses.contains(where: { $0.1 != nil }) { return .queueFailed }
        let progress = statuses.compactMap { $0.0.map { Double($0.progress.progress) } }
        guard !progress.isEmpty, progress.count == ids.count, progress.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return .progress(nil)
        }
        // Every queued ID participates; nil/100% is not a delivery receipt.
        return .progress(progress.reduce(0, +) / Double(ids.count))
    }
}

private enum TelegramEngineUploadAdmission { case rejected, uncertain, accepted(MessageId) }

/// Postbox invokes these hooks on its own queue. Construct them outside the
/// MainActor provider so the callbacks never inherit UI actor isolation.
@MainActor private func enqueueUploadWithReceipt(account: Account, approval: TelegramSendApprovalController,
    peerID: PeerId, message: EnqueueMessage, receipt: TelegramPendingUploadEnqueueReceipt,
    onApproved: @escaping @MainActor () -> Void) -> Signal<TelegramEngineUploadAdmission, NoError> {
    let context = TelegramSendContext(accountID: receipt.target.accountID, chatID: peerID.toInt64(),
        threadID: receipt.target.selectedThreadID, submissionRevision: receipt.preparationID, messageCount: 1)
    let consent = telegramApprovalForDestination(account: account, approval: approval, context: context, title: receipt.target.title, onApproved: onApproved)
    return enqueueUploadAfterApproval(account: account, receipt: receipt, context: context, message: message, approval: consent)
}
private nonisolated func enqueueUploadAfterApproval(account: Account, receipt: TelegramPendingUploadEnqueueReceipt,
    context: TelegramSendContext, message: EnqueueMessage,
    approval: Signal<Result<TelegramPaidSendConsent?, TelegramSendApprovalError>, NoError>) -> Signal<TelegramEngineUploadAdmission, NoError> {
    let receiptSaved = Atomic<Bool>(value: false)
    return telegramEnqueueAfterApproval(account: account, context: context, messages: [message], approval: approval,
        specificAdmission: { receipt.validate(transaction: $0) }, specificCommit: { transaction, ids in
            _ = receiptSaved.swap(receipt.acknowledge(transaction: transaction, messageIDs: ids))
        }) |> map { ids in
            guard let ids else { return .uncertain }
            guard !ids.isEmpty else { return .rejected }
            guard ids.count == 1, let id = ids[0], receiptSaved.with({ $0 }) else { return .uncertain }
            return .accepted(id)
        }
}

/// A failed reply preflight must never degrade into an ordinary media message.
func telegramUploadMessage(caption: String, reference: AnyMediaReference, target: TelegramUploadTarget,
                           replySource: TelegramMessageActionSource?, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false) -> EnqueueMessage? {
    guard let value = try? TelegramFormattedText(text: caption) else { return nil }
    return telegramUploadMessage(caption: value, reference: reference, target: target, replySource: replySource, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler)
}

func telegramUploadMessage(caption: TelegramFormattedText, reference: AnyMediaReference?, target: TelegramUploadTarget,
                           replySource: TelegramMessageActionSource?, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
                           presentation: TelegramUploadPresentation? = nil, maximumUTF16Count: Int = 1024, isOneTime: Bool = false, allowCustomEmoji: Bool = false) -> EnqueueMessage? {
    guard telegramFormattedCaptionCanSend(caption, maximumUTF16Count: maximumUTF16Count, allowCustomEmoji: allowCustomEmoji), target.hasValidReplySource,
          reference != nil || (allowCustomEmoji ? caption.isEditable && caption.text.utf16.count <= 4096 : telegramFormattedTextCanSend(caption)),
          (presentation != nil && reference != nil) || (!captionAboveMedia && !mediaSpoiler) || reference?.media is TelegramMediaImage ||
              (reference?.media as? TelegramMediaFile)?.isVideo == true else { return nil }
    if (reference?.media as? TelegramMediaFile)?.isInstantVideo == true {
        guard caption.text.isEmpty, !captionAboveMedia, !mediaSpoiler else { return nil }
    }
    if isOneTime {
        guard caption.text.isEmpty, !captionAboveMedia, !mediaSpoiler,
              ((reference?.media as? TelegramMediaFile)?.isVoice == true || (reference?.media as? TelegramMediaFile)?.isInstantVideo == true),
              PeerId(target.chatID).namespace == Namespaces.Peer.CloudUser,
              target.chatID != target.accountID else { return nil }
    }
    if let captured = target.replySource {
        guard let replySource, replySource.accountID == captured.accountID,
              replySource.chatID == captured.chatID, replySource.peerID == captured.peerID,
              replySource.namespace == captured.namespace, replySource.messageID == captured.messageID,
              replySource.fingerprint == captured.fingerprint, replySource.threadID == captured.threadID,
              replySource.replyQuote == captured.replyQuote,
              replySource.canReply else { return nil }
    } else if replySource != nil { return nil }
    let reply = replySource.map { source in
        EngineMessageReplySubject(messageId: MessageId(peerId: PeerId(source.peerID), namespace: source.namespace, id: source.messageID),
            quote: source.replyQuote.map { quote in
                EngineMessageReplyQuote(text: quote.formattedText.text, offset: quote.selection?.location,
                    entities: quote.formattedText.engineEntities(), media: source.validatedReplyMediaData.flatMap {
                        PostboxDecoder(buffer: MemoryBuffer(data: $0)).decodeRootObject() as? Media
                    })
            }, todoItemId: nil)
    }
    var attributes = telegramOutgoingTextAttributes(caption)
    if captionAboveMedia { attributes.append(InvertMediaMessageAttribute()) }
    if mediaSpoiler { attributes.append(MediaSpoilerMessageAttribute()) }
    if isOneTime { attributes.append(AutoremoveTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: 0)) }
    return .message(text: caption.text, attributes: attributes, inlineStickers: [:], mediaReference: reference,
        threadId: target.threadID, replyToMessageId: reply, replyToStoryId: nil,
        localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
}

func validUploadCacheFile(_ path: String, size: Int64, expected: Data? = nil) -> Bool {
    guard size >= 0, !path.utf8.contains(0) else { return false }
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == size else { return false }
    guard let expected else { return true }
    guard size <= 1_048_576, expected.count == size else { return false }
    var actual = Data(count: expected.count)
    let readAll = actual.withUnsafeMutableBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
    var current = stat()
    return readAll && actual == expected && lstat(path, &current) == 0 &&
        current.st_dev == info.st_dev && current.st_ino == info.st_ino && current.st_mode & S_IFMT == S_IFREG
}

@MainActor
private final class EngineUploadLease: TelegramUploadLease {
    var preparation: TelegramUploadMediaBoxPreparation?
    let captionValidation = MetaDisposable(), validation = MetaDisposable(), enqueue = MetaDisposable(), pending = MetaDisposable()
    let receive: @MainActor (TelegramUploadEvent) -> Void
    var committing = false
    var validating = false
    var accepted = false
    private(set) var stopped = false
    init(receive: @escaping @MainActor (TelegramUploadEvent) -> Void) { self.receive = receive }
    func stop() {
        guard !stopped else { return }
        stopped = true
        preparation?.stop(); preparation = nil
        captionValidation.dispose(); validation.dispose(); enqueue.dispose(); pending.dispose()
        // This disposes observations only. A committed Postbox send is not recalled.
    }
    isolated deinit { stop() }
}
