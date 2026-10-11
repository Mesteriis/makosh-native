import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

private enum SavedForwardAdmission { case rejected, uncertain, queued }
private enum SavedForwardBegin { case rejected, uncertain, started }
// Postbox executes these closures on its own queue. Construct them outside
// MainActor so Swift does not inherit the UI caller's isolation.
nonisolated func telegramSavedForwardRecover(postbox: Postbox, accountID: Int64) -> Signal<Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { telegramSavedForwardRead(transaction: $0, accountID: accountID) }
}
private nonisolated func savedForwardReject(postbox: Postbox, request: TelegramSavedMessagesForwardRequest) -> Signal<Bool, NoError> {
    postbox.transaction { telegramSavedForwardReject(transaction: $0, accountID: request.accountID, request: request) }
}
nonisolated func telegramSavedForwardAdmission(transaction: Transaction, accountID: Int64,
                                               request: TelegramSavedMessagesForwardRequest) -> Bool {
    guard request.accountID == accountID, request.isValid,
          case let .success(record?) = telegramSavedForwardRead(transaction: transaction, accountID: accountID),
          record.request == request, record.acceptedIDs == nil else { return false }
    return telegramForwardBatch(transaction: transaction, accountID: accountID, draft: request.draft) != nil
}
private nonisolated func savedForwardBegin(postbox: Postbox, accountID: Int64, request: TelegramSavedMessagesForwardRequest) -> Signal<SavedForwardBegin, NoError> {
    postbox.transaction { transaction in
        guard request.accountID == accountID, request.isValid else { return .rejected }
        guard case let .success(current) = telegramSavedForwardRead(transaction: transaction, accountID: accountID),
              current == nil || (current?.acceptedIDs != nil && current?.request.id != request.id) else { return .uncertain }
        guard telegramForwardBatch(transaction: transaction, accountID: accountID, draft: request.draft) != nil else { return .rejected }
        return telegramSavedForwardBegin(transaction: transaction, accountID: accountID, request: request) ? .started : .uncertain
    }
}
private nonisolated func savedForwardEnqueue(account: Account, request: TelegramSavedMessagesForwardRequest) -> Signal<SavedForwardAdmission, NoError> {
    account.postbox.transaction { telegramForwardBatch(transaction: $0, accountID: account.peerId.toInt64(), draft: request.draft) }
    |> mapToSignal { batch -> Signal<SavedForwardAdmission, NoError> in
        guard let batch else { return .single(.rejected) }
        let admitted = Atomic<Bool>(value: false), accepted = Atomic<Bool>(value: false)
        return enqueueMessages(account: account, peerId: account.peerId, messages: batch.messages,
            transactionAdmission: { transaction in
                guard telegramSavedForwardAdmission(transaction: transaction, accountID: account.peerId.toInt64(), request: request) else { return false }
                _ = admitted.swap(true); return true
            }, transactionCommit: { transaction, ids in
                guard ids.count == batch.messages.count else { return }
                var values: [TelegramForwardQueueID] = [], seen = Set<MessageId>()
                for id in ids {
                    guard let id, id.peerId == account.peerId, id.namespace == Namespaces.Message.Local,
                          seen.insert(id).inserted, let message = transaction.getMessage(id), !message.flags.contains(.Incoming) else { return }
                    values.append(.init(peerID: id.peerId.toInt64(), namespace: id.namespace, messageID: id.id))
                }
                _ = accepted.swap(telegramSavedForwardRecordAcceptance(transaction: transaction,
                    accountID: account.peerId.toInt64(), request: request, ids: values))
            }) |> map { ids in
                if accepted.with({ $0 }) { return .queued }
                return !admitted.with({ $0 }) && ids.isEmpty ? .rejected : .uncertain
            }
    }
}
@MainActor final class TelegramEngineSavedMessagesForwardProvider: TelegramSavedMessagesForwardProvider {
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func recover(completion: @escaping @MainActor (Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>) -> Void) -> any TelegramComposerForwardLease {
        let lease = SavedForwardLease(), accountID = self.accountID
        lease.observation.set((telegramSavedForwardRecover(postbox: account.postbox, accountID: accountID)
            |> deliverOnMainQueue).start(next: { result in MainActor.assumeIsolated { if !lease.stopped { completion(result) } } }))
        return lease
    }
    func submit(request: TelegramSavedMessagesForwardRequest,
                receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramComposerForwardLease {
        let lease = SavedForwardLease(), account = self.account
        guard request.accountID == accountID else { receive(.rejected); return lease }
        // Bound account survives UI cancellation through queue/receipt completion.
        let _ = (savedForwardBegin(postbox: account.postbox, accountID: accountID, request: request) |> deliverOnMainQueue).startStandalone(next: { result in
            MainActor.assumeIsolated {
                switch result {
                case .rejected: if !lease.stopped { receive(.rejected) }; return
                case .uncertain: if !lease.stopped { receive(.uncertain) }; return
                case .started: break
                }
                if !lease.stopped { receive(.committing) }
                let _ = (savedForwardEnqueue(account: account, request: request) |> deliverOnMainQueue).startStandalone(next: { result in
                    MainActor.assumeIsolated {
                        switch result {
                        case .queued: if !lease.stopped { receive(.queued) }
                        case .uncertain: if !lease.stopped { receive(.uncertain) }
                        case .rejected:
                            let _ = (savedForwardReject(postbox: account.postbox, request: request)
                                |> deliverOnMainQueue).startStandalone(next: { cleared in
                                    MainActor.assumeIsolated { if !lease.stopped { receive(cleared ? .rejected : .uncertain) } }
                                })
                        }
                    }
                })
            }
        })
        return lease
    }
}
@MainActor final class SavedForwardLease: TelegramComposerForwardLease {
    let observation = MetaDisposable()
    private(set) var stopped = false
    func cancel() { guard !stopped else { return }; stopped = true; observation.dispose() }
    isolated deinit { observation.dispose() }
}
