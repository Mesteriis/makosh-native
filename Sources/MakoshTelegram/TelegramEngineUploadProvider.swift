import Foundation
import Darwin
import UniformTypeIdentifiers
import TelegramCore
import Postbox
import SwiftSignalKit

/// New local media has no remote message provenance or invented cloud credentials.
func telegramUploadMedia(_ file: TelegramUploadFile) -> (LocalFileMediaResource, AnyMediaReference)? {
    let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min...Int64.max), size: file.size)
    let media: Media
    switch file.mode {
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

@MainActor
final class TelegramEngineUploadProvider: TelegramUploadProvider {
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }

    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, caption: TelegramFormattedText,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        let lease = EngineUploadLease(receive: receive)
        let peerID = PeerId(target.chatID)
        guard target.accountID == accountID, target.hasValidReplySource,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peerID.namespace),
              telegramFormattedCaptionCanSend(caption), let (resource, reference) = telegramUploadMedia(file) else {
            receive(.rejected); return lease
        }
        let mediaBox = account.postbox.mediaBox
        lease.keep.set(mediaBox.keepResource(id: resource.id).start())
        // Void copy API suppresses filesystem errors. It is NOT an acknowledgement.
        // Unique resource and FIFO data queue let resourceData observe the resulting file.
        mediaBox.copyResourceData(resource.id, fromTempPath: file.url.path)
        lease.data.set((mediaBox.resourceData(resource, pathExtension: nil,
            option: .complete(waitUntilFetchStatus: false)) |> deliverOnMainQueue).start(next: { [weak lease, account] data in
                guard let lease, !lease.stopped, !lease.validating, !lease.committing,
                      data.complete, data.offset == 0 else { return }
                guard data.size == file.size, validUploadCacheFile(data.path, size: file.size) else {
                    lease.receive(.rejected); lease.stop(); return
                }
                lease.validating = true
                lease.data.dispose()
                let commit: @MainActor (TelegramMessageActionSource?) -> Void = { [weak lease, account] reply in
                    guard let lease, !lease.stopped, !lease.committing else { return }
                    guard let message = telegramUploadMessage(caption: caption, reference: reference, target: target, replySource: reply) else {
                        lease.receive(.rejected); lease.stop(); return
                    }
                    lease.committing = true
                    lease.receive(.committing)
                    guard !lease.stopped else { return }
                    lease.enqueue.set((enqueueMessages(account: account, peerId: peerID, messages: [message])
                    |> deliverOnMainQueue).start(next: { [weak lease, account] ids in
                        guard let lease, !lease.stopped, !lease.accepted else { return }
                        guard let id = ids.first.flatMap({ $0 }) else {
                            lease.receive(.rejected); lease.stop(); return
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
            }))
        return lease
    }
}

/// A failed reply preflight must never degrade into an ordinary media message.
func telegramUploadMessage(caption: String, reference: AnyMediaReference, target: TelegramUploadTarget,
                           replySource: TelegramMessageActionSource?) -> EnqueueMessage? {
    guard let value = try? TelegramFormattedText(text: caption) else { return nil }
    return telegramUploadMessage(caption: value, reference: reference, target: target, replySource: replySource)
}

func telegramUploadMessage(caption: TelegramFormattedText, reference: AnyMediaReference, target: TelegramUploadTarget,
                           replySource: TelegramMessageActionSource?) -> EnqueueMessage? {
    guard telegramFormattedCaptionCanSend(caption), target.hasValidReplySource else { return nil }
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
    return .message(text: caption.text, attributes: telegramOutgoingTextAttributes(caption), inlineStickers: [:], mediaReference: reference,
        threadId: replySource?.threadID, replyToMessageId: reply, replyToStoryId: nil,
        localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
}

func validUploadCacheFile(_ path: String, size: Int64) -> Bool {
    guard size >= 0, !path.utf8.contains(0) else { return false }
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var info = stat()
    return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size == size
}

@MainActor
private final class EngineUploadLease: TelegramUploadLease {
    let keep = MetaDisposable(), data = MetaDisposable(), captionValidation = MetaDisposable(), validation = MetaDisposable(), enqueue = MetaDisposable(), pending = MetaDisposable()
    let receive: @MainActor (TelegramUploadEvent) -> Void
    var committing = false
    var validating = false
    var accepted = false
    private(set) var stopped = false
    init(receive: @escaping @MainActor (TelegramUploadEvent) -> Void) { self.receive = receive }
    func stop() {
        guard !stopped else { return }
        stopped = true
        keep.dispose(); data.dispose(); captionValidation.dispose(); validation.dispose(); enqueue.dispose(); pending.dispose()
        // This disposes observations only. A committed Postbox send is not recalled.
    }
    isolated deinit { stop() }
}
