#if DEBUG
import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Explicit offline fixtures. The synthetic StoreMessages below exercise the
/// owned draft receipt, not a live Account's native forwarding algorithm.
@MainActor final class TelegramSyntheticForwardProvider: TelegramComposerForwardProvider {
    let accountID: Int64 = -1
    private let postbox: Postbox?
    private let simulateReceiptRefusal: Bool
    private let loseAcknowledgement: Bool
    init(postbox: Postbox? = nil, loseAcknowledgement: Bool = false, simulateReceiptRefusal: Bool = false) {
        self.postbox = postbox; self.loseAcknowledgement = loseAcknowledgement; self.simulateReceiptRefusal = simulateReceiptRefusal
    }
    func resolve(draft: TelegramComposerDraft, completion: @escaping @MainActor ([TelegramComposerForwardPreview]?) -> Void) -> any TelegramComposerForwardLease {
        completion(syntheticForwardPreviews(draft)); return SyntheticForwardLease()
    }
    func submit(draft: TelegramComposerDraft, receive: @escaping @MainActor (TelegramComposerForwardEvent) -> Void) -> any TelegramComposerForwardLease {
        let lease = SyntheticForwardLease()
        guard let previews = syntheticForwardPreviews(draft), draft.forwardDisposition == .prepared else {
            receive(.rejected(draft)); return lease
        }
        guard let postbox else {
            let started = TelegramComposerDraft(accountID: draft.accountID, chatID: draft.chatID, input: draft.input,
                revision: draft.revision, replyTarget: draft.replyTarget, forwardIntent: draft.forwardIntent, forwardDisposition: .submissionStarted)
            receive(.committing(started))
            receive(.accepted(TelegramComposerDraft(accountID: draft.accountID, chatID: draft.chatID, input: .empty)))
            return lease
        }
        let lose = loseAcknowledgement
        let _ = (syntheticForwardCommit(postbox: postbox, draft: draft, previews: previews, simulateReceiptRefusal: simulateReceiptRefusal) |> deliverOnMainQueue).startStandalone(next: { result in
            MainActor.assumeIsolated {
                let accepted: TelegramComposerDraft
                switch result {
                case .rejected: if !lease.stopped { receive(.rejected(draft)) }; return
                case .uncertain: if !lease.stopped { receive(.uncertain) }; return
                case let .accepted(value): accepted = value
                }
                if !lease.stopped {
                    let started = TelegramComposerDraft(accountID: draft.accountID, chatID: draft.chatID, input: draft.input,
                        revision: draft.revision, replyTarget: draft.replyTarget, forwardIntent: draft.forwardIntent, forwardDisposition: .submissionStarted)
                    receive(.committing(started))
                    if lose { receive(.uncertain) } else { receive(.receiptAccepted(accepted)) }
                }
                guard !lose else { return }
                let _ = (telegramForwardConsumeAccepted(postbox: postbox, accountID: -1, draft: accepted) |> deliverOnMainQueue).startStandalone(next: { result in
                    MainActor.assumeIsolated {
                        if !lease.stopped {
                            if case let .success(cleared) = result { receive(.accepted(cleared)) } else { receive(.uncertain) }
                        }
                    }
                })
            }
        })
        return lease
    }
    func consumeAccepted(draft: TelegramComposerDraft, completion: @escaping @MainActor (TelegramComposerDraft?) -> Void) -> any TelegramComposerForwardLease {
        let lease = SyntheticForwardLease()
        guard let postbox else { completion(nil); return lease }
        let _ = (telegramForwardConsumeAccepted(postbox: postbox, accountID: -1, draft: draft) |> deliverOnMainQueue).startStandalone(next: { result in
            MainActor.assumeIsolated { if !lease.stopped { completion(try? result.get()) } }
        })
        return lease
    }
}

private nonisolated func syntheticForwardPreviews(_ draft: TelegramComposerDraft) -> [TelegramComposerForwardPreview]? {
    guard draft.accountID == -1, draft.isValid, let intent = draft.forwardIntent else { return nil }
    var result: [TelegramComposerForwardPreview] = []
    for frozen in intent.sources {
        let anchor = MessageIndex(id: MessageId(peerId: PeerId(frozen.peerID), namespace: frozen.namespace, id: frozen.messageID), timestamp: 0)
        guard let item = TelegramSyntheticPages().messages(chatID: frozen.chatID, anchor: anchor).items.first(where: { $0.actionMetadata?.messageID == frozen.messageID }),
              let metadata = item.actionMetadata else { return nil }
        let source = TelegramMessageActionSource(metadata: metadata, accountID: -1, chatID: frozen.chatID)
        guard source.canForward, TelegramComposerForwardSource(source: source) == frozen else { return nil }
        result.append(.init(id: item.id, author: item.author, text: item.text, formattedText: metadata.formattedText,
            canCopy: source.canCopy, hasCaption: !item.attachments.isEmpty && !item.text.isEmpty))
    }
    return result
}
private enum SyntheticForwardCommit { case rejected, uncertain, accepted(TelegramComposerDraft) }
private nonisolated func syntheticForwardCommit(postbox: Postbox, draft: TelegramComposerDraft, previews: [TelegramComposerForwardPreview], simulateReceiptRefusal: Bool) -> Signal<SyntheticForwardCommit, NoError> {
    postbox.transaction { transaction in
        guard telegramForwardBeginSubmission(transaction: transaction, accountID: -1, draft: draft) else { return .rejected }
        var texts = previews.map(\.text)
        if !draft.text.isEmpty { texts.insert(draft.text, at: 0) }
        var ids: [TelegramForwardQueueID] = []
        for text in texts {
            let uniqueID = Int64.random(in: Int64.min...Int64.max)
            let message = StoreMessage(peerId: PeerId(draft.chatID), namespace: Namespaces.Message.Local,
                globallyUniqueId: uniqueID, groupingKey: nil, threadId: nil, timestamp: 100,
                flags: [.Unsent], tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: nil,
                text: text, attributes: [], media: [])
            guard let id = transaction.addMessages([message], location: .Random)[uniqueID] else { return .uncertain }
            ids.append(.init(peerID: id.peerId.toInt64(), namespace: id.namespace, messageID: id.id))
        }
        guard !simulateReceiptRefusal else { return .uncertain }
        guard telegramForwardRecordAcceptance(transaction: transaction, accountID: -1, draft: draft, ids: ids),
              case let .success(accepted) = telegramComposerDraftRead(transaction: transaction, accountID: -1, chatID: draft.chatID), let accepted else { return .uncertain }
        return .accepted(accepted)
    }
}
@MainActor private final class SyntheticForwardLease: TelegramComposerForwardLease {
    private(set) var stopped = false
    func cancel() { stopped = true }
}
#endif
