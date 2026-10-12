import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

@MainActor protocol TelegramSelectedMessagesDeleteProvider: AnyObject {
    var accountID: Int64 { get }
    func start(request: TelegramSelectedMessagesDeleteRequest,
               receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease
}

/// Runs on the Postbox transaction queue, including the final fresh authority check.
func telegramSelectedMessagesDeleteAdmission(transaction: Transaction, accountID: Int64,
                                             request: TelegramSelectedMessagesDeleteRequest) -> Bool {
    guard request.accountID == accountID, telegramSelectedMessagesDeleteAllowed(request) else { return false }
    let limits = currentLimitsConfiguration(transaction: transaction)
    for source in request.sources {
        let id = MessageId(peerId: PeerId(source.peerID), namespace: source.namespace, id: source.messageID)
        guard let message = transaction.getMessage(id) else { return false }
        let fresh = TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message, limits: limits),
            accountID: accountID, chatID: request.chatID)
        guard fresh.fingerprint.utf8.elementsEqual(source.fingerprint.utf8), fresh.threadID == source.threadID,
              request.forEveryone ? fresh.canDeleteForEveryone : fresh.canDeleteLocally else { return false }
        if source.peerID != request.chatID {
            guard let group = transaction.getPeer(id.peerId) as? TelegramGroup,
                  group.migrationReference?.peerId.toInt64() == request.chatID else { return false }
        }
    }
    return true
}

func telegramDeleteSelectedMessages(postbox: Postbox, stateManager: AccountStateManager?, accountID: Int64,
                                    request: TelegramSelectedMessagesDeleteRequest) -> Signal<Bool, NoError> {
    makoshDeleteSelectedMessages(postbox: postbox, stateManager: stateManager,
        messageIds: request.sources.map { MessageId(peerId: PeerId($0.peerID), namespace: $0.namespace, id: $0.messageID) },
        type: request.forEveryone ? .forEveryone : .forLocalPeer,
        transactionAdmission: { transaction in
            telegramSelectedMessagesDeleteAdmission(transaction: transaction, accountID: accountID, request: request)
        })
}

@MainActor final class TelegramEngineSelectedMessagesDeleteProvider: TelegramSelectedMessagesDeleteProvider {
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func start(request: TelegramSelectedMessagesDeleteRequest,
               receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
        let lease = SelectedDeleteLease()
        guard request.accountID == accountID, telegramSelectedMessagesDeleteAllowed(request) else {
            receive(.rejected); return lease
        }
        receive(.committing)
        guard !lease.stopped else { return lease }
        let signal = telegramDeleteSelectedMessages(postbox: account.postbox, stateManager: account.stateManager,
            accountID: accountID, request: request)
        lease.subscription.set((signal |> deliverOnMainQueue).start(next: { [weak lease] queued in
            MainActor.assumeIsolated {
                guard let lease, !lease.stopped else { return }
                receive(queued ? .queued : .rejected)
            }
        }))
        return lease
    }
}
@MainActor private final class SelectedDeleteLease: TelegramMessageActionsLease {
    let subscription = MetaDisposable()
    private(set) var stopped = false
    func cancel() { guard !stopped else { return }; stopped = true; subscription.dispose() }
    isolated deinit { subscription.dispose() }
}

#if DEBUG
/// Explicit preview simulation: no Postbox mutation and no remote-delete claim.
@MainActor final class TelegramSyntheticSelectedMessagesDeleteProvider: TelegramSelectedMessagesDeleteProvider {
    let accountID: Int64 = -1
    func start(request: TelegramSelectedMessagesDeleteRequest,
               receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
        let lease = SelectedDeleteLease()
        guard request.accountID == accountID, telegramSelectedMessagesDeleteAllowed(request) else {
            receive(.rejected); return lease
        }
        receive(.committing); receive(.queued)
        return lease
    }
}
#endif
