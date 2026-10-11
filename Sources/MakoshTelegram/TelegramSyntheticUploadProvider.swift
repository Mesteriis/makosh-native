#if DEBUG
import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

/// Explicit UI fixture only. An injected synthetic Postbox can exercise the
/// owned queue receipt; no Account, Telegram network or delivery is involved.
@MainActor
final class TelegramSyntheticUploadProvider: TelegramUploadProvider {
    let accountID: Int64 = -1
    private let postbox: Postbox?
    private let loseAcknowledgement: Bool
    init(postbox: Postbox? = nil, loseAcknowledgement: Bool = false) {
        self.postbox = postbox; self.loseAcknowledgement = loseAcknowledgement
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText, captionAboveMedia: Bool = false,
                receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        let lease = SyntheticUploadLease()
        guard target.accountID == accountID, target.hasValidReplySource, telegramFormattedCaptionCanSend(caption),
              !captionAboveMedia || file.mode == .photo else {
            receive(.rejected); return lease
        }
        let postbox = self.postbox, loseAcknowledgement = self.loseAcknowledgement
        lease.task = Task { [weak lease] in
            do {
                try await Task.sleep(for: .milliseconds(600))
                guard lease != nil else { return }
                receive(.committing)
                if let postbox, let lease {
                    let receipt = TelegramPendingUploadEnqueueReceipt(preparationID: preparationID,
                        target: target, file: file, caption: caption, captionAboveMedia: captionAboveMedia)
                    lease.operation.set((syntheticUploadCommit(postbox: postbox, receipt: receipt)
                        |> deliverOnMainQueue).start(next: { event in
                            MainActor.assumeIsolated {
                                if case .accepted = event, loseAcknowledgement { receive(.uncertain) }
                                else { receive(event) }
                            }
                        }))
                    return
                }
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

private func syntheticUploadCommit(postbox: Postbox, receipt: TelegramPendingUploadEnqueueReceipt) -> Signal<TelegramUploadEvent, NoError> {
    postbox.transaction { transaction in
        guard receipt.validate(transaction: transaction), let (_, reference) = telegramUploadMedia(receipt.file) else { return .rejected }
        let uniqueID = Int64.random(in: Int64.min...Int64.max)
        var attributes = telegramOutgoingTextAttributes(receipt.caption)
        if receipt.captionAboveMedia { attributes.append(InvertMediaMessageAttribute()) }
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
    let operation = MetaDisposable()
    func stop() { task?.cancel(); task = nil; operation.dispose() }
    isolated deinit { stop() }
}
#endif
