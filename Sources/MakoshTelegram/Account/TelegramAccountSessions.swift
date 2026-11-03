import Foundation
import Combine
import TelegramApi
import SwiftSignalKit

public struct TelegramAccountSession: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let device, platform, systemVersion, app, appVersion, ip, country, region: String
    public let apiID, created, active: Int32
    public let official, pending, acceptsSecretChats, acceptsCalls: Bool
    public var isCurrent: Bool { id == 0 }
}
public struct TelegramSessionsSnapshot: Equatable, Sendable {
    public let accountID: Int64
    public let sessions: [TelegramAccountSession]
    public let ttlDays: Int32
    public var current: TelegramAccountSession? { sessions.first { $0.isCurrent } }
    public var pending: [TelegramAccountSession] { ordered.filter { !$0.isCurrent && $0.pending } }
    public var others: [TelegramAccountSession] { ordered.filter { !$0.isCurrent && !$0.pending } }
    private var ordered: [TelegramAccountSession] { sessions.sorted { $0.active == $1.active ? $0.id < $1.id : $0.active > $1.active } }
    var isValid: Bool {
        !sessions.isEmpty && sessions.count <= 256 && sessions.filter(\.isCurrent).count == 1
            && Set(sessions.map(\.id)).count == sessions.count && (1...365).contains(ttlDays)
    }
    func permits(_ change: TelegramSessionChange) -> Bool {
        guard isValid else { return false }
        switch change {
        case let .terminate(target): return !target.isCurrent && sessions.contains(target)
        case .terminateOthers: return sessions.contains { !$0.isCurrent }
        case let .ttl(days): return [7, 31, 93, 186].contains(days) && days != ttlDays
        case let .secretChats(target, value): return !target.pending && sessions.contains(target) && target.acceptsSecretChats != value
        case let .calls(target, value): return !target.pending && sessions.contains(target) && target.acceptsCalls != value
        }
    }
}
public enum TelegramSessionChange: Equatable, Sendable {
    case terminate(TelegramAccountSession), terminateOthers
    case ttl(Int32), secretChats(TelegramAccountSession, Bool), calls(TelegramAccountSession, Bool)
}
enum TelegramSessionsError: Error, Equatable, Sendable { case unavailable, changed, failed, freshReset, uncertain }
func telegramSessionsSnapshot(_ response: Api.account.Authorizations, accountID: Int64) -> TelegramSessionsSnapshot? {
    guard case let .authorizations(ttl, values) = response, values.count <= 256 else { return nil }
    var sessions: [TelegramAccountSession] = []
    for value in values {
        guard case let .authorization(flags, hash, device, platform, system, api, app, version, created, active, ip, country, region) = value,
              hash != 0 || flags & 1 != 0 else { return nil }
        sessions.append(.init(id: flags & 1 != 0 ? 0 : hash, device: device, platform: platform, systemVersion: system,
            app: app, appVersion: version, ip: ip, country: country, region: region, apiID: api, created: created, active: active,
            official: flags & 2 != 0, pending: flags & 4 != 0, acceptsSecretChats: flags & 8 == 0, acceptsCalls: flags & 16 == 0))
    }
    let result = TelegramSessionsSnapshot(accountID: accountID, sessions: sessions, ttlDays: ttl)
    return result.isValid ? result : nil
}
private func sameDevice(_ lhs: TelegramAccountSession, _ rhs: TelegramAccountSession) -> Bool {
    lhs.id == rhs.id && lhs.created == rhs.created && lhs.apiID == rhs.apiID && lhs.device == rhs.device && lhs.platform == rhs.platform
}
func telegramAdmitSessionChange(expected: TelegramSessionsSnapshot, current: TelegramSessionsSnapshot, change: TelegramSessionChange) -> Bool {
    guard expected.accountID == current.accountID, expected.permits(change), current.isValid,
          let oldSelf = expected.current, let newSelf = current.current, sameDevice(oldSelf, newSelf) else { return false }
    switch change {
    case .terminateOthers:
        return expected.sessions.count == current.sessions.count && expected.sessions.allSatisfy { old in current.sessions.contains { sameDevice(old, $0) } }
    case .ttl: return expected.ttlDays == current.ttlDays
    case let .terminate(target): return current.sessions.contains { sameDevice(target, $0) }
    case let .secretChats(target, _):
        return current.sessions.contains { sameDevice(target, $0) && !$0.pending && $0.acceptsSecretChats == target.acceptsSecretChats }
    case let .calls(target, _):
        return current.sessions.contains { sameDevice(target, $0) && !$0.pending && $0.acceptsCalls == target.acceptsCalls }
    }
}
func telegramSessionWriteError(code: Int32, change: TelegramSessionChange) -> TelegramSessionsError {
    if code == 406 {
        switch change { case .terminate, .terminateOthers: return .freshReset; default: return .failed }
    }
    return (400..<500).contains(code) ? .failed : .uncertain
}

@MainActor protocol TelegramSessionsRequest: AnyObject { func cancel() }
@MainActor protocol TelegramSessionsProvider: AnyObject {
    var accountID: Int64 { get }
    func load(receive: @escaping @MainActor (Result<TelegramSessionsSnapshot, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest
    func apply(_ change: TelegramSessionChange, expected: TelegramSessionsSnapshot,
        receive: @escaping @MainActor (Result<Void, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest
}
@MainActor public final class TelegramSessionsController: ObservableObject {
    public enum MutationStatus: Equatable { case idle, saving, saved, changed, failed, freshReset, uncertain }
    @Published public private(set) var snapshot: TelegramSessionsSnapshot?
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public private(set) var mutationStatus: MutationStatus = .idle
    @Published public private(set) var contextID = UUID()
    private var provider: (any TelegramSessionsProvider)?
    private var read: (any TelegramSessionsRequest)?, write: (any TelegramSessionsRequest)?
    private var readID: UUID?, writeID: UUID?
    private var readDeadline: Task<Void, Never>?, writeDeadline: Task<Void, Never>?
    private var uncertainAccounts: Set<Int64> = []
    public init() {}
    isolated deinit { read?.cancel(); write?.cancel(); readDeadline?.cancel(); writeDeadline?.cancel() }
    func bind(_ provider: (any TelegramSessionsProvider)?) { close(); self.provider = provider }
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
        guard let provider else { snapshot = nil; status = .failed; return }
        let token = UUID(), context = contextID, accountID = provider.accountID
        readID = token; status = .loading
        readDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.readID == token else { return }
            self.readID = nil; self.read?.cancel(); self.read = nil; self.status = .timedOut
        }
        let request = provider.load { [weak self] result in
            guard let self, self.readID == token, self.contextID == context else { return }
            self.readID = nil; self.readDeadline?.cancel(); self.readDeadline = nil
            self.read?.cancel(); self.read = nil
            switch result {
            case .failure: self.status = .failed
            case let .success(snapshot):
                guard snapshot.accountID == accountID, snapshot.isValid else { self.snapshot = nil; self.status = .failed; return }
                self.snapshot = snapshot; self.status = .ready
                if reconcile, self.mutationStatus == .uncertain {
                    self.uncertainAccounts.remove(accountID); self.mutationStatus = .idle
                }
            }
        }
        if readID == token { read = request } else { request.cancel() }
    }
    @discardableResult public func apply(_ change: TelegramSessionChange, contextID: UUID) -> Bool {
        guard self.contextID == contextID, status == .ready, mutationStatus != .saving, mutationStatus != .uncertain,
              let provider, let snapshot, snapshot.accountID == provider.accountID, snapshot.permits(change) else { return false }
        let token = UUID(); writeID = token; mutationStatus = .saving
        writeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.writeID == token else { return }; self.timeoutMutation()
        }
        let request = provider.apply(change, expected: snapshot) { [weak self] result in
            guard let self, self.writeID == token, self.contextID == contextID else { return }
            self.writeID = nil; self.writeDeadline?.cancel(); self.writeDeadline = nil; self.write?.cancel(); self.write = nil
            switch result {
            case .success: self.mutationStatus = .saved; self.load(reconcile: false)
            case .failure(.changed): self.mutationStatus = .changed; self.load(reconcile: false)
            case .failure(.freshReset): self.mutationStatus = .freshReset
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
