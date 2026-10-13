#if DEBUG
import Foundation
import TelegramCore
import Postbox

@MainActor final class TelegramSyntheticSecretChatProvider: TelegramSecretChatProvider {
    let accountID: Int64 = 101
    private var sessions: [Int64: TelegramSecretSessionSnapshot] = [:]
    private var observers: [UUID: (Int64, @MainActor (Result<TelegramSecretSessionSnapshot, TelegramSecretChatError>) -> Void)] = [:]
    private var sequence: Int32 = 100
    private func session(_ id: Int64) -> TelegramSecretSessionSnapshot? {
        if let value = sessions[id] { return value }
        guard let nativeID = telegramSecretPeerID(id), [44, 45, 46].contains(nativeID.id._internalGetInt64Value()) else { return nil }
        let state: TelegramSecretConversation.State = nativeID.id._internalGetInt64Value() == 44 ? .active : nativeID.id._internalGetInt64Value() == 45 ? .handshake : .terminated
        let value = make(id: id, state: state, ttl: nil, revision: 0); sessions[id] = value; return value
    }
    private func make(id: Int64, state: TelegramSecretConversation.State, ttl: Int32?, revision: Int) -> TelegramSecretSessionSnapshot {
        .init(accountID: accountID, chatID: id, regularPeerID: 42, title: "Synthetic Alice", state: state,
            verification: state == .active ? .init(sha1: Data(0..<20), sha256: Data(32..<64)) : nil,
            layer: state == .active ? 144 : nil, ttl: ttl, keyAvailable: state == .active,
            revision: String(format: "%064x", revision))
    }
    func loadCreation(peerID: Int64, receive: @escaping @MainActor (Result<TelegramSecretCreationBasis, TelegramSecretChatError>) -> Void) -> any TelegramSecretChatRequest {
        let request = SyntheticSecretRequest()
        guard peerID == 42 else { receive(.failure(.unavailable)); return request }
        receive(.success(.init(accountID: accountID, peerID: peerID, title: "Synthetic Alice", username: "synthetic_alice",
            canCreate: true, premiumRequired: false, revision: String(repeating: "a", count: 64))))
        return request
    }
    func create(basis: TelegramSecretCreationBasis, receive: @escaping @MainActor (TelegramSecretCreationEvent) -> Bool) -> any TelegramSecretChatRequest {
        let request = SyntheticSecretRequest()
        request.task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled, basis.accountID == self.accountID, basis.peerID == 42, receive(.committing) else { return }
            self.sequence += 1
            let id = PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(Int64(self.sequence))).toInt64()
            let value = self.make(id: id, state: .handshake, ttl: nil, revision: 1); self.sessions[id] = value
            _ = receive(.created(value))
        }
        return request
    }
    func observeSession(chatID: Int64, receive: @escaping @MainActor (Result<TelegramSecretSessionSnapshot, TelegramSecretChatError>) -> Void) -> any TelegramSecretChatRequest {
        let request = SyntheticSecretRequest(), token = UUID()
        guard let value = session(chatID) else { receive(.failure(.unavailable)); return request }
        observers[token] = (chatID, receive); request.onCancel = { [weak self] in self?.observers[token] = nil }
        receive(.success(value)); return request
    }
    func setTTL(basis: TelegramSecretSessionSnapshot, timeout: Int32?, receive: @escaping @MainActor (TelegramSecretTTLEvent) -> Bool) -> any TelegramSecretChatRequest {
        let request = SyntheticSecretRequest()
        request.task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, !Task.isCancelled, self.session(basis.chatID) == basis, basis.canSetTTL, receive(.committing) else { return }
            let value = self.make(id: basis.chatID, state: .active, ttl: timeout, revision: Int(self.sequence)); self.sequence += 1
            self.sessions[basis.chatID] = value
            for (id, observer) in self.observers.values where id == basis.chatID { observer(.success(value)) }
            _ = receive(.queued(.init(accountID: self.accountID, chatID: basis.chatID, previousTTL: basis.ttl, timeout: timeout,
                sessionRevision: basis.revision, namespace: Namespaces.Message.Local, messageID: self.sequence)))
        }
        return request
    }
}
@MainActor private final class SyntheticSecretRequest: TelegramSecretChatRequest {
    var task: Task<Void, Never>?
    var onCancel: (() -> Void)?
    func cancel() { task?.cancel(); task = nil; onCancel?(); onCancel = nil }
    isolated deinit { cancel() }
}
#endif
