import Foundation
import Postbox
import TelegramCore
import TelegramApi
import SwiftSignalKit

func telegramCallUserInput(transaction: Transaction, accountID: Int64, peerID: Int64) -> Api.InputUser? {
    guard telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser,
          let id = telegramManagementPeerID(peerID), id.namespace == Namespaces.Peer.CloudUser, peerID != accountID,
          let user = transaction.getPeer(id) as? TelegramUser, !user.isDeleted, user.botInfo == nil,
          case let .personal(hash) = user.accessHash, hash != 0 else { return nil }
    return .inputUser(userId: id.id._internalGetInt64Value(), accessHash: hash)
}
func telegramCommitCallPeer(transaction: Transaction, result: Api.users.UserFull, accountID: Int64, peerID: Int64) -> TelegramCallPeer? {
    guard let basis = telegramCallPeer(result: result, accountID: accountID, peerID: peerID),
          let id = telegramManagementPeerID(peerID) else { return nil }
    let chats: [Api.Chat], users: [Api.User]
    switch result { case let .userFull(_, c, u): chats = c; users = u }
    guard let directory = makoshGroupPeerDirectory(transaction: transaction, chats: chats, users: users, requiredIds: [id]) else { return nil }
    makoshCommitGroupPeerDirectory(transaction: transaction, accountPeerId: PeerId(accountID), directory: directory)
    return basis
}
func telegramCallIncoming(states: [CallSessionRingingState], accountID: Int64, peers: [PeerId: Peer]) -> [TelegramIncomingCall]? {
    guard telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser, states.count <= 32,
          Set(states.map(\.id)).count == states.count else { return nil }
    var result: [TelegramIncomingCall] = []
    for row in states {
        guard row.conferenceSource == nil, row.otherParticipants.isEmpty else { continue }
        let number = row.peerId.toInt64()
        guard telegramManagementPeerID(number) == row.peerId, row.peerId.namespace == Namespaces.Peer.CloudUser,
              number != accountID else { return nil }
        let cached = peers[row.peerId].map(telegramPeerTitle)
        let title = cached.flatMap { !$0.isEmpty && $0.utf16.count <= 512 && !$0.contains("\0") ? $0 : nil } ?? "Пользователь \(number)"
        let value = TelegramIncomingCall(id: row.id, accountID: accountID, peerID: number, title: title, isVideo: row.isVideo)
        guard value.isValid else { return nil }; result.append(value)
    }
    return result
}
private func callUnwrap<T>(_ signal: Signal<T?, NoError>) -> Signal<T, TelegramCallError> {
    signal |> castError(TelegramCallError.self) |> mapToSignal { value in
        guard let value else { return .fail(.unavailable) }; return .single(value)
    }
}
@MainActor final class TelegramAccountCallEngine: TelegramCallEngine {
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func peer(_ id: Int64) -> Signal<TelegramCallPeer, TelegramCallError> {
        Self.peer(account: account, accountID: accountID, peerID: id)
    }
    // Native signal and Postbox callbacks run on their owning queues. Keep
    // their data transformations outside actor isolation; the provider delivers
    // completed snapshots to MainActor before touching presentation state.
    nonisolated private static func peer(account: Account, accountID: Int64, peerID: Int64) -> Signal<TelegramCallPeer, TelegramCallError> {
        return callUnwrap(account.postbox.transaction { telegramCallUserInput(transaction: $0, accountID: accountID, peerID: peerID) })
            |> mapToSignal { input in
                account.network.request(Api.functions.users.getFullUser(id: input), automaticFloodWait: false)
                    |> mapError { _ in TelegramCallError.failed } |> mapToSignal { result in
                        callUnwrap(account.postbox.transaction { telegramCommitCallPeer(transaction: $0, result: result, accountID: accountID, peerID: peerID) })
                    }
            }
    }
    func incoming() -> Signal<[TelegramIncomingCall], TelegramCallError> {
        Self.incoming(account: account, accountID: accountID)
    }
    nonisolated private static func incoming(account: Account, accountID: Int64) -> Signal<[TelegramIncomingCall], TelegramCallError> {
        return account.callSessionManager.ringingStates() |> castError(TelegramCallError.self) |> mapToSignal { rows in
            callUnwrap(account.postbox.transaction { transaction in
                var peers: [PeerId: Peer] = [:]
                for row in rows { if let peer = transaction.getPeer(row.peerId) { peers[row.peerId] = peer } }
                return telegramCallIncoming(states: rows, accountID: accountID, peers: peers)
            })
        }
    }
    func request(peer: TelegramCallPeer, video: Bool, callID: UUID) -> Signal<UUID, TelegramCallError> {
        guard peer.isValid, peer.accountID == accountID, peer.canVoice, !video || peer.canVideo else { return .fail(.unavailable) }
        return account.callSessionManager.request(peerId: PeerId(peer.peerID), isVideo: video, enableVideo: peer.canVideo, internalId: callID) |> castError(TelegramCallError.self)
    }
    func observe(callID: UUID) -> Signal<CallSession, TelegramCallError> { account.callSessionManager.callState(internalId: callID) |> castError(TelegramCallError.self) }
    func receiveSignaling(callID: UUID, receive: @escaping @MainActor (Result<Data, TelegramCallError>) -> Void) -> any TelegramCallRequest {
        let inbox = TelegramCallMediaInbox { value in
            MainActor.assumeIsolated {
                switch value { case let .signaling(data): receive(.success(data)); case .failed: receive(.failure(.failed)); default: break }
            }
        }
        let disposable = Self.receiveSignaling(account: account, callID: callID, inbox: inbox)
        return CallSignalingRequest(inbox: inbox, disposable: disposable)
    }
    nonisolated private static func receiveSignaling(account: Account, callID: UUID, inbox: TelegramCallMediaInbox) -> Disposable {
        account.callSessionManager.beginReceivingCallSignalingData(internalId: callID) { packets in
            guard packets.count <= 256 else { _ = inbox.enqueue(.signaling(Data())); return }
            for packet in packets { if !inbox.enqueue(.signaling(Data(packet))) { break } }
        }
    }
    func accept(callID: UUID) { account.callSessionManager.accept(internalId: callID) }
    func drop(callID: UUID, reason: DropCallReason) { account.callSessionManager.drop(internalId: callID, reason: reason, debugLog: .single(nil)) }
    func send(callID: UUID, data: Data) { account.callSessionManager.sendSignalingData(internalId: callID, data: data) }
    func updateVideo(callID: UUID, enabled: Bool) { account.callSessionManager.updateCallType(internalId: callID, type: enabled ? .video : .audio) }
}
@MainActor private final class CallSignalingRequest: TelegramCallRequest {
    let inbox: TelegramCallMediaInbox
    let disposable: Disposable
    init(inbox: TelegramCallMediaInbox, disposable: Disposable) { self.inbox = inbox; self.disposable = disposable }
    func cancel() { inbox.revoke(); disposable.dispose() }
    isolated deinit { inbox.revoke(); disposable.dispose() }
}
