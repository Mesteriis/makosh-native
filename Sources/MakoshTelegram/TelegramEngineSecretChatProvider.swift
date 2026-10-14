import Foundation
import Postbox
import TelegramCore
import TelegramApi
import SwiftSignalKit

private func secretUnwrap<T>(_ signal: Signal<T?, NoError>) -> Signal<T, TelegramSecretChatError> {
    signal |> castError(TelegramSecretChatError.self) |> mapToSignal { value in
        guard let value else { return .fail(.unavailable) }; return .single(value)
    }
}
private func secretExistingID(transaction: Transaction, userID: PeerId) -> Int64? {
    transaction.getAssociatedPeerIds(userID).compactMap { id -> TelegramSecretChat? in
        guard telegramSecretPeerID(id.toInt64()) != nil, let chat = transaction.getPeer(id) as? TelegramSecretChat,
              chat.regularPeerId == userID, chat.embeddedState != .terminated else { return nil }; return chat
    }.max { $0.creationDate < $1.creationDate }?.id.toInt64()
}
private func secretCreation(account: Account, peerID: Int64) -> Signal<TelegramSecretCreationBasis, TelegramSecretChatError> {
    guard let id = telegramManagementPeerID(peerID), id.namespace == Namespaces.Peer.CloudUser, id != account.peerId else { return .fail(.unavailable) }
    return secretUnwrap(account.postbox.transaction { transaction -> Api.InputUser? in
        guard let user = transaction.getPeer(id) as? TelegramUser, !user.isDeleted, user.botInfo == nil,
              case let .personal(hash) = user.accessHash, hash != 0 else { return nil }
        return .inputUser(userId: id.id._internalGetInt64Value(), accessHash: hash)
    }) |> mapToSignal { input in
        account.network.request(Api.functions.users.getUsers(id: [input]), automaticFloodWait: false)
            |> mapError { _ in TelegramSecretChatError.failed } |> mapToSignal { users in
                secretUnwrap(account.postbox.transaction { transaction -> (TelegramUser, Api.InputUser)? in
                    guard users.count == 1 else { return nil }
                    switch users[0] {
                    case let .user(flags, _, number, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _):
                        guard flags & (1 << 20) == 0, number == id.id._internalGetInt64Value() else { return nil }
                    case .userEmpty: return nil
                    }
                    guard let directory = makoshGroupPeerDirectory(transaction: transaction, chats: [], users: users, requiredIds: [id]),
                          let user = directory.peers[id] as? TelegramUser, !user.isDeleted, user.botInfo == nil,
                          case let .personal(hash) = user.accessHash, hash != 0 else { return nil }
                    makoshCommitGroupPeerDirectory(transaction: transaction, accountPeerId: account.peerId, directory: directory)
                    return (user, .inputUser(userId: id.id._internalGetInt64Value(), accessHash: hash))
                })
            } |> mapToSignal { user, freshInput in
                account.network.request(Api.functions.users.getRequirementsToContact(id: [freshInput]), automaticFloodWait: false)
                    |> mapError { _ in TelegramSecretChatError.failed } |> mapToSignal { requirements in
                        guard requirements.count == 1 else { return .fail(.unavailable) }
                        let premium: Bool
                        switch requirements[0] {
                        case .requirementToContactPremium: premium = true
                        case .requirementToContactEmpty, .requirementToContactPaidMessages: premium = false
                        }
                        return secretUnwrap(account.postbox.transaction { transaction in
                            telegramSecretCreationBasis(peer: user, accountID: account.peerId.toInt64(), premiumRequired: premium,
                                existingSecretID: secretExistingID(transaction: transaction, userID: id))
                        })
                    }
            }
    }
}

@MainActor final class TelegramEngineSecretChatProvider: TelegramSecretChatProvider {
    let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func loadCreation(peerID: Int64, receive: @escaping @MainActor (Result<TelegramSecretCreationBasis, TelegramSecretChatError>) -> Void) -> any TelegramSecretChatRequest {
        let request = SecretNativeRequest(); request.start(secretCreation(account: account, peerID: peerID), receive: receive); return request
    }
    func create(basis: TelegramSecretCreationBasis, receive: @escaping @MainActor (TelegramSecretCreationEvent) -> Bool) -> any TelegramSecretChatRequest {
        let request = SecretNativeRequest(), account = account
        guard basis.isValid, basis.accountID == accountID, basis.canCreate else { _ = receive(.failed(.unavailable)); return request }
        request.start(secretCreation(account: account, peerID: basis.peerID)) { [weak request] result in
            guard let request, !request.stopped else { return }
            guard case let .success(fresh) = result else { _ = receive(.failed(.failed)); return }
            guard fresh == basis, fresh.canCreate else { _ = receive(.failed(.changed)); return }
            guard receive(.committing), !request.stopped else { request.cancel(); return }
            let creation = TelegramEngine(account: account).peers.createSecretChat(peerId: PeerId(basis.peerID))
                |> mapError { error -> TelegramSecretChatError in
                    switch error { case .generic: return .uncertain; case .limitExceeded: return .limitExceeded; case .premiumRequired: return .premiumRequired }
                } |> mapToSignal { id -> Signal<TelegramSecretSessionSnapshot, TelegramSecretChatError> in
                    secretUnwrap(account.postbox.transaction {
                        telegramSecretSessionSnapshot(transaction: $0, accountID: account.peerId.toInt64(), chatID: id.toInt64())
                    })
                }
            request.start(creation) { result in
                switch result { case let .success(value): _ = receive(.created(value)); case let .failure(error): _ = receive(.failed(error)) }
            }
        }
        return request
    }
    func observeSession(chatID: Int64, receive: @escaping @MainActor (Result<TelegramSecretSessionSnapshot, TelegramSecretChatError>) -> Void) -> any TelegramSecretChatRequest {
        let request = SecretNativeRequest()
        guard let id = telegramSecretPeerID(chatID) else { receive(.failure(.unavailable)); return request }
        let account = account
        let signal = account.postbox.combinedView(keys: [.basicPeer(id), .peerChatState(peerId: id), .peer(peerId: id, components: [])])
            |> mapToSignal { _ in account.postbox.transaction { telegramSecretSessionSnapshot(transaction: $0, accountID: account.peerId.toInt64(), chatID: chatID) } }
            |> distinctUntilChanged |> deliverOnMainQueue
        request.disposable.add(signal.start(next: { [weak request] value in
            MainActor.assumeIsolated {
                guard request?.stopped == false else { return }
                receive(value.map(Result.success) ?? .failure(.unavailable))
            }
        }))
        return request
    }
    func setTTL(basis: TelegramSecretSessionSnapshot, timeout: Int32?, receive: @escaping @MainActor (TelegramSecretTTLEvent) -> Bool) -> any TelegramSecretChatRequest {
        let request = SecretNativeRequest(), account = account
        guard basis.isValid, basis.canSetTTL, basis.accountID == accountID, let id = telegramSecretPeerID(basis.chatID),
              timeout.map({ $0 > 0 }) ?? true, timeout != basis.ttl else { _ = receive(.failed(.unavailable)); return request }
        request.start(secretUnwrap(account.postbox.transaction {
            telegramSecretSessionSnapshot(transaction: $0, accountID: basis.accountID, chatID: basis.chatID)
        })) { [weak request] result in
            guard let request, !request.stopped else { return }
            guard case let .success(fresh) = result, fresh == basis else { _ = receive(.failed(.changed)); return }
            guard receive(.committing), !request.stopped else { request.cancel(); return }
            let admitted = request.admitted
            let queued = account.postbox.transaction { transaction -> TelegramSecretTTLReceipt? in
                guard let timestamp = Int32(exactly: Int64(Date().timeIntervalSince1970.rounded(.down))),
                      let message = makoshEnqueueSecretTTL(transaction: transaction, accountPeerId: account.peerId, peerId: id,
                        timeout: timeout, timestamp: timestamp, isSupportUser: false, admission: { transaction in
                            admitted.with { $0 } && telegramSecretSessionSnapshot(transaction: transaction, accountID: basis.accountID, chatID: basis.chatID) == basis
                        }) else { return nil }
                return .init(accountID: basis.accountID, chatID: basis.chatID, previousTTL: basis.ttl, timeout: timeout,
                    sessionRevision: basis.revision, namespace: message.namespace, messageID: message.id)
            }
            request.start(secretUnwrap(queued)) { result in
                switch result { case let .success(receipt): _ = receive(.queued(receipt)); case .failure: _ = receive(.failed(.uncertain)) }
            }
        }
        return request
    }
}
@MainActor private final class SecretNativeRequest: TelegramSecretChatRequest {
    let disposable = DisposableSet()
    let admitted = Atomic(value: true)
    var stopped = false
    func start<T>(_ signal: Signal<T, TelegramSecretChatError>, receive: @escaping @MainActor (Result<T, TelegramSecretChatError>) -> Void) {
        guard !stopped else { return }; var delivered = false
        disposable.add((signal |> take(1) |> deliverOnMainQueue).start(next: { [weak self] value in
            MainActor.assumeIsolated { guard self?.stopped == false else { return }; delivered = true; receive(.success(value)) }
        }, error: { [weak self] error in
            MainActor.assumeIsolated { if self?.stopped == false { delivered = true; receive(.failure(error)) } }
        }, completed: { [weak self] in
            MainActor.assumeIsolated { if self?.stopped == false && !delivered { receive(.failure(.uncertain)) } }
        }))
    }
    func cancel() { stopped = true; _ = admitted.swap(false); disposable.dispose() }
    isolated deinit { _ = admitted.swap(false); disposable.dispose() }
}
