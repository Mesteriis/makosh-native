#if DEBUG
import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

/// Explicit UI fixture only. An injected synthetic Postbox can exercise the
/// owned queue receipt; no Account, Telegram network or delivery is involved.
@MainActor
final class TelegramSyntheticUploadProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = -1
    private let postbox: Postbox?
    private let loseAcknowledgement: Bool
    init(postbox: Postbox? = nil, loseAcknowledgement: Bool = false) {
        self.postbox = postbox; self.loseAcknowledgement = loseAcknowledgement
    }
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        guard let postbox else { receive(.rejected); return SyntheticUploadLease() }
        let loseAcknowledgement = self.loseAcknowledgement
        return TelegramUploadBatchSubmission(postbox: postbox, accountID: accountID, items: items, draft: draft,
            target: target, enqueue: { receipt, messages in
                syntheticUploadBatchCommit(postbox: postbox, receipt: receipt, messages: messages,
                    loseAcknowledgement: loseAcknowledgement)
            }, receive: receive)
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        let lease = SyntheticUploadLease()
        guard target.accountID == accountID, target.hasValidReplySource, file.metadata == nil, telegramFormattedCaptionCanSend(caption),
              (!captionAboveMedia && !mediaSpoiler) || file.mode == .photo || file.mode == .video else {
            receive(.rejected); return lease
        }
        let postbox = self.postbox, loseAcknowledgement = self.loseAcknowledgement
        lease.task = Task { [weak lease] in
            do {
                try await Task.sleep(for: .milliseconds(600))
                guard let lease, !lease.stopped else { return }
                if let postbox {
                    lease.preparation = TelegramUploadMediaBoxPreparation(mediaBox: postbox.mediaBox, file: file) { [weak lease] result in
                        guard let lease, !lease.stopped else { return }
                        guard case let .success(prepared) = result else { receive(.rejected); lease.stop(); return }
                        receive(.committing)
                        guard !lease.stopped else { return }
                        let receipt = TelegramPendingUploadEnqueueReceipt(preparationID: preparationID,
                            target: target, file: file, caption: caption, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler,
                            localResourceID: prepared.resource.fileId, videoThumbnail: prepared.videoThumbnail, videoCover: prepared.videoCover)
                        lease.operation.set((syntheticUploadCommit(postbox: postbox, receipt: receipt, reference: prepared.reference)
                            |> deliverOnMainQueue).start(next: { [weak lease] event in
                                MainActor.assumeIsolated {
                                    guard let lease, !lease.stopped else { return }
                                    if case .accepted = event, loseAcknowledgement { receive(.uncertain) }
                                    else { receive(event) }
                                }
                            }))
                    }
                    return
                }
                receive(.committing)
                guard !lease.stopped else { return }
                try await Task.sleep(for: .milliseconds(600))
                receive(.accepted("synthetic-local:" + UUID().uuidString))
                for progress in [0.1, 0.5, 1.0] {
                    receive(.progress(progress))
                    try await Task.sleep(for: .milliseconds(600))
                }
                receive(.progress(nil))
            } catch { /* Only stops fixture observation, never a real send. */ }
        }
        return lease
    }
}

nonisolated func telegramUploadBatchEnqueueLocally(postbox: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
                                                 messages: [EnqueueMessage], accountPeerID: PeerId = PeerId(1),
                                                 loseAcknowledgement: Bool = false) -> Signal<TelegramUploadBatchAdmission, NoError> {
    telegramUploadBatchEnqueue(receipt: receipt, messages: messages) { messages, admission, commit in
        enqueueMessagesLocally(postbox: postbox, accountPeerId: accountPeerID, isSupportUser: false,
            timestamp: 100, peerId: PeerId(receipt.target.chatID), messages: messages,
            transactionAdmission: admission, transactionCommit: commit)
    } |> map { admission in
        if case .accepted = admission, loseAcknowledgement { return .uncertain }
        return admission
    }
}

private nonisolated func syntheticUploadBatchCommit(postbox: Postbox, receipt: TelegramUploadBatchEnqueueReceipt,
                                                   messages: [EnqueueMessage], loseAcknowledgement: Bool) -> Signal<TelegramUploadBatchAdmission, NoError> {
    // The scoped Makosh account sentinel (-1) is not a serialized native PeerId.
    // Both peers belong exclusively to this isolated DEBUG Postbox fixture.
    let author = PeerId(1), peer = PeerId(receipt.target.chatID)
    guard peer.namespace == Namespaces.Peer.CloudUser else { return .single(.rejected) }
    func user(_ id: PeerId) -> TelegramUser {
        TelegramUser(id: id, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil, phone: nil,
            photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil, usernames: [], storiesHidden: nil,
            nameColor: nil, backgroundEmojiId: nil, profileColor: nil, profileBackgroundEmojiId: nil,
            subscriberCount: nil, verificationIconFileId: nil)
    }
    return postbox.transaction { transaction in
        transaction.updatePeersInternal([user(author), user(peer)], update: { current, new in current ?? new })
        transaction.updatePeerCachedData(peerIds: [peer], update: { _, current in current ?? CachedUserData() })
        return true
    } |> mapToSignal { _ in
        telegramUploadBatchEnqueueLocally(postbox: postbox, receipt: receipt, messages: messages,
            accountPeerID: author, loseAcknowledgement: loseAcknowledgement)
    }
}

private func syntheticUploadCommit(postbox: Postbox, receipt: TelegramPendingUploadEnqueueReceipt, reference: AnyMediaReference) -> Signal<TelegramUploadEvent, NoError> {
    postbox.transaction { transaction in
        guard receipt.validate(transaction: transaction) else { return .rejected }
        let uniqueID = Int64.random(in: Int64.min...Int64.max)
        var attributes = telegramOutgoingTextAttributes(receipt.caption)
        if receipt.captionAboveMedia { attributes.append(InvertMediaMessageAttribute()) }
        if receipt.mediaSpoiler { attributes.append(MediaSpoilerMessageAttribute()) }
        let message = StoreMessage(peerId: PeerId(receipt.target.chatID), namespace: Namespaces.Message.Local,
            globallyUniqueId: uniqueID, groupingKey: nil, threadId: receipt.target.replySource?.threadID,
            timestamp: 100, flags: [.Unsent], tags: [], globalTags: [], localTags: [],
            forwardInfo: nil, authorId: nil, text: receipt.caption.text,
            attributes: attributes, media: [reference.media])
        let id = transaction.addMessages([message], location: .Random)[uniqueID]
        guard receipt.acknowledge(transaction: transaction, messageIDs: [id]), let id else { return .uncertain }
        return .accepted("\(id.peerId.toInt64()):\(id.namespace):\(id.id)")
    }
}

@MainActor
private final class SyntheticUploadLease: TelegramUploadLease {
    var task: Task<Void, Never>?
    var preparation: TelegramUploadMediaBoxPreparation?
    private(set) var stopped = false
    let operation = MetaDisposable()
    func stop() {
        guard !stopped else { return }
        stopped = true; task?.cancel(); task = nil
        preparation?.stop(); preparation = nil; operation.dispose()
    }
    isolated deinit { stop() }
}
#endif
