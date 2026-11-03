import Foundation
import Combine
import Postbox
import TelegramCore

func telegramBlockedNativeID(_ rawID: Int64) -> Int64? {
    guard rawID > 0, rawID <= 0x00ff_ffff_ffff_ffff else { return nil }
    return PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(rawID)).toInt64()
}

public struct TelegramBlockedUser: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let title: String
}
/// Keep non-user peers in the complete read without treating their IDs as users.
/// Mutations remain scoped to cloud users; other entries are explicitly read-only.
public struct TelegramBlockedOtherPeer: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case group, channel }
    public let kind: Kind
    public let rawID: Int64
    public var id: String { "\(kind.rawValue):\(rawID)" }
    public var title: String { kind == .group ? "Заблокированная группа" : "Заблокированный канал" }
}
public struct TelegramBlockedUsersSnapshot: Equatable, Sendable {
    public let accountID: Int64
    public let users: [TelegramBlockedUser]
    public let otherPeers: [TelegramBlockedOtherPeer]
    init(accountID: Int64, users: [TelegramBlockedUser], otherPeers: [TelegramBlockedOtherPeer] = []) {
        self.accountID = accountID; self.users = users; self.otherPeers = otherPeers
    }
}
public struct TelegramBlockedUserChange: Equatable, Sendable {
    public let accountID: Int64
    public let contextID: UUID
    public let userID: Int64
    public let title: String
    public let wasBlocked: Bool
}
extension TelegramBlockedUsersSnapshot {
    var isValid: Bool {
        accountID != 0 && users.count + otherPeers.count <= 10_000 && Set(users.map(\.id)).count == users.count
            && users.allSatisfy { telegramBlockedNativeID($0.id) != nil && !$0.title.isEmpty && $0.title.count <= 512 }
            && Set(otherPeers.map(\.id)).count == otherPeers.count
            && otherPeers.allSatisfy { telegramBlockedNativeID($0.rawID) != nil }
    }
}
@MainActor protocol TelegramBlockedUsersProvider: AnyObject {
    var accountID: Int64 { get }
    func load(receive: @escaping @MainActor (Result<TelegramBlockedUsersSnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest
    func apply(_ change: TelegramBlockedUserChange, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest
}
@MainActor public final class TelegramBlockedUsersController: ObservableObject {
    @Published public private(set) var snapshot: TelegramBlockedUsersSnapshot?
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public private(set) var mutationStatus: TelegramPrivacyController.MutationStatus = .idle
    @Published public private(set) var contextID = UUID()
    private var provider: (any TelegramBlockedUsersProvider)?
    private var read: (any TelegramPrivacyRequest)?, write: (any TelegramPrivacyRequest)?
    private var readID: UUID?, writeID: UUID?
    private var readDeadline: Task<Void, Never>?, writeDeadline: Task<Void, Never>?
    private var uncertainAccounts: Set<Int64> = []
    public init() {}
    isolated deinit { read?.cancel(); write?.cancel(); readDeadline?.cancel(); writeDeadline?.cancel() }
    func bind(_ provider: (any TelegramBlockedUsersProvider)?) { close(); self.provider = provider }
    public func open() {
        close()
        if let id = provider?.accountID, uncertainAccounts.contains(id) { mutationStatus = .uncertain }
        load(reconcile: false)
    }
    public func close() {
        if mutationStatus == .saving, let id = provider?.accountID { uncertainAccounts.insert(id) }
        contextID = UUID(); readID = nil; writeID = nil
        read?.cancel(); read = nil; write?.cancel(); write = nil
        readDeadline?.cancel(); readDeadline = nil; writeDeadline?.cancel(); writeDeadline = nil
        snapshot = nil; status = .idle; mutationStatus = .idle
    }
    public func refresh() { guard mutationStatus != .saving else { return }; load(reconcile: true) }
    private func load(reconcile: Bool) {
        contextID = UUID(); readID = nil; read?.cancel(); read = nil; readDeadline?.cancel(); readDeadline = nil
        snapshot = nil
        guard let provider else { status = .failed; return }
        let token = UUID(), context = contextID, account = provider.accountID
        readID = token; status = .loading
        readDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.readID == token else { return }
            self.readID = nil; self.read?.cancel(); self.read = nil; self.status = .timedOut
        }
        let request = provider.load { [weak self] result in
            guard let self, self.readID == token, self.contextID == context else { return }
            self.readID = nil; self.readDeadline?.cancel(); self.readDeadline = nil; self.read?.cancel(); self.read = nil
            switch result {
            case .failure: self.status = .failed
            case let .success(value):
                guard value.accountID == account, value.isValid else { self.status = .failed; return }
                self.snapshot = value; self.status = .ready
                if reconcile, self.mutationStatus == .uncertain { self.uncertainAccounts.remove(account); self.mutationStatus = .idle }
            }
        }
        if readID == token { read = request } else { request.cancel() }
    }
    public func change(userID: Int64, title: String) -> TelegramBlockedUserChange? {
        guard status == .ready, mutationStatus != .saving, mutationStatus != .uncertain,
              let snapshot, snapshot.accountID == provider?.accountID, let nativeID = telegramBlockedNativeID(userID), nativeID != snapshot.accountID,
              !title.isEmpty, title.count <= 512 else { return nil }
        return .init(accountID: snapshot.accountID, contextID: contextID, userID: userID, title: title,
            wasBlocked: snapshot.users.contains { $0.id == userID })
    }
    @discardableResult public func apply(_ change: TelegramBlockedUserChange) -> Bool {
        guard change == self.change(userID: change.userID, title: change.title), let provider else { return false }
        let token = UUID(), context = contextID
        writeID = token; mutationStatus = .saving
        writeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.writeID == token else { return }; self.timeoutMutation()
        }
        let request = provider.apply(change) { [weak self] result in
            guard let self, self.writeID == token, self.contextID == context else { return }
            self.writeID = nil; self.writeDeadline?.cancel(); self.writeDeadline = nil; self.write?.cancel(); self.write = nil
            switch result {
            case .success: self.mutationStatus = .saved; self.load(reconcile: false)
            case .failure(.changed): self.mutationStatus = .changed; self.load(reconcile: false)
            case .failure(.uncertain): self.uncertainAccounts.insert(provider.accountID); self.mutationStatus = .uncertain
            case .failure: self.mutationStatus = .failed
            }
        }
        if writeID == token { write = request } else { request.cancel() }
        return true
    }
    func timeoutMutation() {
        guard mutationStatus == .saving, let id = provider?.accountID else { return }
        uncertainAccounts.insert(id); writeID = nil; write?.cancel(); write = nil; writeDeadline?.cancel(); writeDeadline = nil
        mutationStatus = .uncertain
    }
}
