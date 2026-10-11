#if DEBUG
import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

/// Offline StoreMessages/receipt fixture; never executes a live Account enqueue.
@MainActor final class TelegramSyntheticSavedMessagesForwardProvider: TelegramSavedMessagesForwardProvider {
    let accountID: Int64 = -1
    private let postbox: Postbox?
    private let loseAcknowledgement: Bool
    private var memoryRecord: TelegramSavedMessagesForwardRecord?
    init(postbox: Postbox? = nil, loseAcknowledgement: Bool = false) {
        self.postbox = postbox; self.loseAcknowledgement = loseAcknowledgement
    }
    func recover(completion: @escaping @MainActor (Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>) -> Void) -> any TelegramComposerForwardLease {
        let lease = SavedForwardLease()
        guard let postbox else { completion(.success(memoryRecord)); return lease }
        lease.observation.set((telegramSavedForwardRecover(postbox: postbox, accountID: accountID)
            |> deliverOnMainQueue).start(next: { result in MainActor.assumeIsolated { if !lease.stopped { completion(result) } } }))
        return lease
    }
    func submit(request: TelegramSavedMessagesForwardRequest,
                receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramComposerForwardLease {
        let lease = SavedForwardLease()
        guard request.accountID == accountID, request.isValid, let previews = syntheticForwardPreviews(request.draft) else {
            receive(.rejected); return lease
        }
        guard let postbox else {
            guard memoryRecord == nil || (memoryRecord?.acceptedIDs != nil && memoryRecord?.request.id != request.id) else { receive(.uncertain); return lease }
            memoryRecord = .init(request: request); receive(.committing)
            let ids = request.sources.enumerated().map { TelegramForwardQueueID(peerID: request.destinationChatID, namespace: Namespaces.Message.Local, messageID: Int32($0.offset + 1)) }
            memoryRecord = .init(request: request, acceptedIDs: ids)
            receive(loseAcknowledgement ? .uncertain : .queued); return lease
        }
        let lose = loseAcknowledgement
        let _ = (syntheticSavedForwardCommit(postbox: postbox, request: request, previews: previews)
            |> deliverOnMainQueue).startStandalone(next: { result in MainActor.assumeIsolated {
                guard !lease.stopped else { return }
                switch result {
                case .failure: receive(.uncertain)
                case .success(false): receive(.rejected)
                case .success(true): receive(.committing); receive(lose ? .uncertain : .queued)
                }
            } })
        return lease
    }
}
nonisolated func syntheticSavedForwardCommit(postbox: Postbox, request: TelegramSavedMessagesForwardRequest,
                                             previews: [TelegramComposerForwardPreview]) -> Signal<Result<Bool, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        guard request.accountID == -1, request.isValid, previews.count == request.sources.count else { return .success(false) }
        guard telegramSavedForwardBegin(transaction: transaction, accountID: -1, request: request) else { return .failure(.incompatibleData) }
        var ids: [TelegramForwardQueueID] = []
        for preview in previews {
            let unique = Int64.random(in: Int64.min...Int64.max)
            let message = StoreMessage(peerId: PeerId(request.destinationChatID), namespace: Namespaces.Message.Local,
                globallyUniqueId: unique, groupingKey: nil, threadId: nil, timestamp: 100, flags: [.Unsent],
                tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: nil, text: preview.text, attributes: [], media: [])
            guard let id = transaction.addMessages([message], location: .Random)[unique] else { return .failure(.unavailable) }
            ids.append(.init(peerID: id.peerId.toInt64(), namespace: id.namespace, messageID: id.id))
        }
        return telegramSavedForwardRecordAcceptance(transaction: transaction, accountID: -1, request: request, ids: ids)
            ? .success(true) : .failure(.unavailable)
    }
}
#endif
