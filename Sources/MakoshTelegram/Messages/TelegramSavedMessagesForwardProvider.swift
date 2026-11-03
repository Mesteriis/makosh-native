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
          record.request == request, record.acceptedIDs == nil,
          telegramSavedForwardOriginIsCurrent(transaction: transaction, request: request) else { return false }
    return telegramForwardBatch(transaction: transaction, accountID: accountID, draft: request.draft) != nil
}
private nonisolated func savedForwardBegin(postbox: Postbox, accountID: Int64, request: TelegramSavedMessagesForwardRequest) -> Signal<SavedForwardBegin, NoError> {
    postbox.transaction { transaction in
        guard request.accountID == accountID, request.isValid else { return .rejected }
        guard case let .success(current) = telegramSavedForwardRead(transaction: transaction, accountID: accountID),
              current == nil || (current?.acceptedIDs != nil && current?.request.id != request.id) else { return .uncertain }
        guard telegramForwardBatch(transaction: transaction, accountID: accountID, draft: request.draft) != nil,
              telegramSavedForwardOriginIsCurrent(transaction: transaction, request: request) else { return .rejected }
        return telegramSavedForwardBegin(transaction: transaction, accountID: accountID, request: request) ? .started : .uncertain
    }
}
private nonisolated func savedForwardEnqueue(account: Account, request: TelegramSavedMessagesForwardRequest,
    context: TelegramSendContext, consent: TelegramPaidSendConsent?) -> Signal<SavedForwardAdmission, NoError> {
    account.postbox.transaction { telegramForwardBatch(transaction: $0, accountID: account.peerId.toInt64(), draft: request.draft) }
    |> mapToSignal { batch -> Signal<SavedForwardAdmission, NoError> in
        guard let batch else { return .single(.rejected) }
        let accepted = Atomic<Bool>(value: false)
        return telegramEnqueueApprovedMessages(account: account, context: context, messages: batch.messages, consent: consent,
            specificAdmission: { transaction in
                telegramSavedForwardAdmission(transaction: transaction, accountID: account.peerId.toInt64(), request: request)
            }, specificCommit: { transaction, ids in
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
                return ids?.isEmpty == true ? .rejected : .uncertain
            }
    }
}
@MainActor final class TelegramEngineSavedMessagesForwardProvider: TelegramSavedMessagesForwardProvider {
    private let account: Account
    private let approval: TelegramSendApprovalController
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account, approval: TelegramSendApprovalController) { self.account = account; self.approval = approval }
    func recover(completion: @escaping @MainActor (Result<TelegramSavedMessagesForwardRecord?, TelegramComposerDraftPersistenceError>) -> Void) -> any TelegramComposerForwardLease {
        let lease = SavedForwardLease(), accountID = self.accountID
        lease.observation.set((telegramSavedForwardRecover(postbox: account.postbox, accountID: accountID)
            |> deliverOnMainQueue).start(next: { result in MainActor.assumeIsolated { if !lease.stopped { completion(result) } } }))
        return lease
    }
    func submit(request: TelegramSavedMessagesForwardRequest,
                receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramComposerForwardLease {
        let lease = SavedForwardLease()
        guard request.accountID == accountID else { receive(.rejected); return lease }
        let context = TelegramSendContext(accountID: accountID, chatID: request.destinationChatID, threadID: nil,
            submissionRevision: request.id, messageCount: request.sources.count)
        receive(.awaitingApproval)
        lease.observation.set((telegramApprovalForDestination(account: account, approval: approval, context: context)
            |> deliverOnMainQueue).start(next: { result in
                MainActor.assumeIsolated {
                    guard !lease.stopped else { return }
                    guard case let .success(consent) = result else { receive(.rejected); return }
                    lease.continueAfterApproval(notify: { receive(.committing) }, begin: {
                        self.submitApproved(request: request, context: context, consent: consent, lease: lease, receive: receive)
                    })
                }
            }))
        return lease
    }
    private func submitApproved(request: TelegramSavedMessagesForwardRequest, context: TelegramSendContext,
        consent: TelegramPaidSendConsent?, lease: SavedForwardLease,
        receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) {
        let account = self.account
        // Bound account survives UI cancellation through queue/receipt completion.
        let _ = (savedForwardBegin(postbox: account.postbox, accountID: accountID, request: request) |> deliverOnMainQueue).startStandalone(next: { result in
            MainActor.assumeIsolated {
                switch result {
                case .rejected: if !lease.stopped { receive(.rejected) }; return
                case .uncertain: if !lease.stopped { receive(.uncertain) }; return
                case .started: break
                }
                let _ = (savedForwardEnqueue(account: account, request: request, context: context, consent: consent) |> deliverOnMainQueue).startStandalone(next: { result in
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
    }
}
@MainActor final class SavedForwardLease: TelegramComposerForwardLease {
    let observation = MetaDisposable()
    private(set) var stopped = false
    func continueAfterApproval(notify: () -> Void, begin: () -> Void) {
        guard !stopped else { return }
        notify()
        guard !stopped else { return }
        begin()
    }
    func cancel() { guard !stopped else { return }; stopped = true; observation.dispose() }
    isolated deinit { observation.dispose() }
}
