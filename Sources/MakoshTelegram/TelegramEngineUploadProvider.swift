import Foundation
import Darwin
import UniformTypeIdentifiers
import TelegramCore
import Postbox
import SwiftSignalKit

/// New local media has no remote message provenance or invented cloud credentials.
func telegramUploadMedia(_ file: TelegramUploadFile, videoThumbnail: TelegramUploadVideoThumbnailResource? = nil) -> (LocalFileMediaResource, AnyMediaReference)? {
    guard file.mode == .video || file.video == nil else { return nil }
    guard file.mode == .video ? videoThumbnail?.isValid == true : videoThumbnail == nil else { return nil }
    var resourceID = Int64.random(in: Int64.min...Int64.max)
    while resourceID == videoThumbnail?.id { resourceID = Int64.random(in: Int64.min...Int64.max) }
    let resource = LocalFileMediaResource(fileId: resourceID, size: file.size)
    let media: Media
    switch file.mode {
    case .video:
        guard let attributes = telegramUploadVideoAttributes(file), let videoThumbnail else { return nil }
        media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: resource.fileId),
            partialReference: nil, resource: resource, previewRepresentations: [videoThumbnail.representation], videoThumbnails: [],
            immediateThumbnailData: nil, mimeType: "video/mp4", size: file.size,
            attributes: attributes, alternativeRepresentations: [])
    case .file:
        let mime = UTType(filenameExtension: URL(fileURLWithPath: file.name).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        media = TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: resource.fileId),
            partialReference: nil, resource: resource, previewRepresentations: [], videoThumbnails: [],
            immediateThumbnailData: nil, mimeType: mime, size: file.size,
            attributes: [.FileName(fileName: telegramAttachmentName(file.name))], alternativeRepresentations: [])
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
final class TelegramEngineUploadProvider: TelegramUploadProvider {
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }

    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        let lease = EngineUploadLease(receive: receive)
        let peerID = PeerId(target.chatID)
        guard target.accountID == accountID, target.hasValidReplySource,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peerID.namespace),
              telegramFormattedCaptionCanSend(caption), (!captionAboveMedia && !mediaSpoiler) || file.mode != .file else {
            receive(.rejected); return lease
        }
        lease.preparation = TelegramUploadMediaBoxPreparation(mediaBox: account.postbox.mediaBox, file: file) { [weak lease, account] result in
            guard let lease, !lease.stopped, !lease.validating, !lease.committing else { return }
            guard case let .success(prepared) = result else {
                lease.receive(.rejected); lease.stop(); return
            }
            let resource = prepared.resource, reference = prepared.reference
            lease.validating = true
            let commit: @MainActor (TelegramMessageActionSource?) -> Void = { [weak lease, account] reply in
                guard let lease, !lease.stopped, !lease.committing else { return }
                guard let message = telegramUploadMessage(caption: caption, reference: reference, target: target, replySource: reply, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler) else {
                    lease.receive(.rejected); lease.stop(); return
                }
                lease.committing = true
                lease.receive(.committing)
                guard !lease.stopped else { return }
                let receipt = TelegramPendingUploadEnqueueReceipt(preparationID: preparationID,
                    target: target, file: file, caption: caption, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler,
                    localResourceID: resource.fileId, videoThumbnail: prepared.videoThumbnail)
                lease.enqueue.set((enqueueUploadWithReceipt(account: account, peerID: peerID,
                    message: message, receipt: receipt)
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

private enum TelegramEngineUploadAdmission { case rejected, uncertain, accepted(MessageId) }

/// Postbox invokes these hooks on its own queue. Construct them outside the
/// MainActor provider so the callbacks never inherit UI actor isolation.
private nonisolated func enqueueUploadWithReceipt(account: Account, peerID: PeerId, message: EnqueueMessage,
                                                 receipt: TelegramPendingUploadEnqueueReceipt) -> Signal<TelegramEngineUploadAdmission, NoError> {
    let receiptSaved = Atomic<Bool>(value: false)
    return enqueueMessages(account: account, peerId: peerID, messages: [message],
        transactionAdmission: { receipt.validate(transaction: $0) },
        transactionCommit: { transaction, ids in
            _ = receiptSaved.swap(receipt.acknowledge(transaction: transaction, messageIDs: ids))
        }) |> map { ids in
            guard !ids.isEmpty else { return .rejected }
            // An unexpected result after enqueue cannot prove rejection.
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

func telegramUploadMessage(caption: TelegramFormattedText, reference: AnyMediaReference, target: TelegramUploadTarget,
                           replySource: TelegramMessageActionSource?, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false) -> EnqueueMessage? {
    guard telegramFormattedCaptionCanSend(caption), target.hasValidReplySource,
          (!captionAboveMedia && !mediaSpoiler) || reference.media is TelegramMediaImage ||
              (reference.media as? TelegramMediaFile)?.isVideo == true else { return nil }
    if let captured = target.replySource {
        guard let replySource, replySource.accountID == captured.accountID,
              replySource.chatID == captured.chatID, replySource.peerID == captured.peerID,
              replySource.namespace == captured.namespace, replySource.messageID == captured.messageID,
              replySource.fingerprint == captured.fingerprint, replySource.threadID == captured.threadID,
              replySource.canReply else { return nil }
    } else if replySource != nil { return nil }
    let reply = replySource.map {
        EngineMessageReplySubject(messageId: MessageId(peerId: PeerId($0.peerID), namespace: $0.namespace, id: $0.messageID),
            quote: nil, todoItemId: nil)
    }
    var attributes = telegramOutgoingTextAttributes(caption)
    if captionAboveMedia { attributes.append(InvertMediaMessageAttribute()) }
    if mediaSpoiler { attributes.append(MediaSpoilerMessageAttribute()) }
    return .message(text: caption.text, attributes: attributes, inlineStickers: [:], mediaReference: reference,
        threadId: replySource?.threadID, replyToMessageId: reply, replyToStoryId: nil,
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
