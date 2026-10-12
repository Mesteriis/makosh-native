import Foundation
import Postbox
import SwiftSignalKit

/// A validated candidate only: observing never imports or writes a draft.
struct TelegramServerDraftUpdate: Equatable, Sendable {
    let draft: TelegramComposerDraft
    let nativeFingerprint: Data
    let basisRevision: UUID?
    var localRevision: UUID? = nil
}

struct TelegramServerDraftObservationContext: Equatable, Sendable {
    let accountID: Int64
    let chatID: Int64
    var threadID: Int64? = nil
    let generation: UUID
}

struct TelegramServerDraftObservationEvent: Sendable {
    let context: TelegramServerDraftObservationContext
    let result: Result<TelegramServerDraftUpdate, TelegramComposerDraftPersistenceError>
}

@MainActor protocol TelegramServerDraftObserving: AnyObject {
    var accountID: Int64 { get }
    func observe(chatID: Int64, context: TelegramServerDraftObservationContext,
        receive: @escaping @MainActor (TelegramServerDraftObservationEvent) -> Void) -> Disposable
}

@MainActor final class TelegramPostboxServerDraftObserver: TelegramServerDraftObserving {
    let accountID: Int64
    private let postbox: Postbox
    private var active: ServerDraftObservationLease?
    private var previous: ServerDraftObservationSignature?

    init(postbox: Postbox, accountID: Int64) {
        self.postbox = postbox; self.accountID = accountID
    }

    deinit { active?.dispose() }

    func observe(chatID: Int64, context: TelegramServerDraftObservationContext,
        receive: @escaping @MainActor (TelegramServerDraftObservationEvent) -> Void) -> Disposable {
        active?.dispose()
        active = nil
        previous = nil
        guard context.accountID == accountID, context.chatID == chatID else { return EmptyDisposable }
        let lease = ServerDraftObservationLease()
        active = lease
        lease.set(serverDraftObservationSignal(postbox: postbox, accountID: accountID, chatID: chatID, threadID: context.threadID)
            .start(next: { [weak self, weak lease] result in
                MainActor.assumeIsolated {
                    guard let self, let lease, self.active === lease, lease.isActive else { return }
                    switch result {
                    case .success(nil):
                        self.previous = nil
                    case let .success(update?):
                        guard update.draft.accountID == context.accountID, update.draft.chatID == context.chatID, update.draft.threadID == context.threadID,
                              update.draft.isValid else {
                            self.failure(.incompatibleData, context: context, receive: receive)
                            return
                        }
                        let signature = ServerDraftObservationSignature.update(update.nativeFingerprint, update.basisRevision)
                        guard self.previous != signature else { return }
                        self.previous = signature
                        receive(.init(context: context, result: .success(update)))
                    case let .failure(error):
                        self.failure(error, context: context, receive: receive)
                    }
                }
            }))
        return lease
    }

    private func failure(_ error: TelegramComposerDraftPersistenceError,
        context: TelegramServerDraftObservationContext,
        receive: @MainActor (TelegramServerDraftObservationEvent) -> Void) {
        let signature = ServerDraftObservationSignature.failure(error)
        guard previous != signature else { return }
        previous = signature
        receive(.init(context: context, result: .failure(error)))
    }
}

private enum ServerDraftObservationSignature: Equatable {
    case update(Data, UUID?)
    case failure(TelegramComposerDraftPersistenceError)
}

/// Owns one subscription. A returned old lease cannot dispose a later binding.
private final class ServerDraftObservationLease: Disposable, @unchecked Sendable {
    private let lock = NSLock()
    private var disposed = false
    private let native = MetaDisposable()

    var isActive: Bool { lock.withLock { !disposed } }
    func set(_ disposable: Disposable) { native.set(disposable) }
    func dispose() {
        let changed = lock.withLock {
            guard !disposed else { return false }
            disposed = true
            return true
        }
        if changed { native.dispose() }
    }
    deinit { native.dispose() }
}

private nonisolated func serverDraftObservationSignal(postbox: Postbox, accountID: Int64, chatID: Int64, threadID: Int64?)
    -> Signal<Result<TelegramServerDraftUpdate?, TelegramComposerDraftPersistenceError>, NoError> {
    let key: PostboxViewKey = threadID == nil ? .chatInterfaceState(peerId: PeerId(chatID))
        : .messageHistoryThreadIndex(id: PeerId(chatID), summaryComponents: .init(components: [:]))
    return postbox.combinedView(keys: [key])
        |> mapToSignal { _ in
            postbox.transaction { transaction -> Result<TelegramServerDraftUpdate?, TelegramComposerDraftPersistenceError> in
                do { return .success(try telegramServerDraftUpdate(transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID)) }
                catch let error as TelegramComposerDraftPersistenceError { return .failure(error) }
                catch { return .failure(.incompatibleData) }
            }
        }
        |> deliverOnMainQueue
}
