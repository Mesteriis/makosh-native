import Foundation
import Combine
import TelegramApi

public struct TelegramWebSession: Identifiable, Equatable, Sendable {
    public let id, botID: Int64
    public let domain, browser, platform: String
    public let created, active: Int32
    public let ip, region: String
}
public struct TelegramWebSessionsSnapshot: Equatable, Sendable {
    public let accountID: Int64
    public let sessions: [TelegramWebSession]
    public var ordered: [TelegramWebSession] { sessions.sorted { $0.active == $1.active ? $0.id < $1.id : $0.active > $1.active } }
    var isValid: Bool {
        sessions.count <= 256 && Set(sessions.map(\.id)).count == sessions.count && sessions.allSatisfy {
            $0.id != 0 && $0.botID > 0 && $0.created >= 0 && $0.active >= $0.created && !$0.domain.isEmpty &&
            [$0.domain, $0.browser, $0.platform, $0.ip, $0.region].allSatisfy { text in
                text.utf8.count <= 1024 && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            }
        }
    }
    func permits(_ change: TelegramWebSessionChange) -> Bool {
        guard isValid else { return false }
        switch change { case let .terminate(target): return sessions.contains(target); case .terminateAll: return !sessions.isEmpty }
    }
}
public enum TelegramWebSessionChange: Equatable, Sendable { case terminate(TelegramWebSession), terminateAll }
func telegramWebSessionsSnapshot(_ response: Api.account.WebAuthorizations, accountID: Int64) -> TelegramWebSessionsSnapshot? {
    guard case let .webAuthorizations(authorizations, _) = response, authorizations.count <= 256 else { return nil }
    let sessions = authorizations.map { value -> TelegramWebSession in
        switch value {
        case let .webAuthorization(hash, bot, domain, browser, platform, created, active, ip, region):
            return .init(id: hash, botID: bot, domain: domain, browser: browser, platform: platform, created: created, active: active, ip: ip, region: region)
        }
    }
    let snapshot = TelegramWebSessionsSnapshot(accountID: accountID, sessions: sessions)
    return snapshot.isValid ? snapshot : nil
}
func telegramAdmitWebSessionChange(expected: TelegramWebSessionsSnapshot, current: TelegramWebSessionsSnapshot, change: TelegramWebSessionChange) -> Bool {
    guard expected.accountID == current.accountID, expected.permits(change), current.isValid else { return false }
    func same(_ a: TelegramWebSession, _ b: TelegramWebSession) -> Bool {
        a.id == b.id && a.botID == b.botID && a.created == b.created && a.domain == b.domain && a.browser == b.browser && a.platform == b.platform
    }
    switch change {
    case let .terminate(target): return current.sessions.contains { same(target, $0) }
    case .terminateAll: return expected.sessions.count == current.sessions.count && expected.sessions.allSatisfy { a in current.sessions.contains { same(a, $0) } }
    }
}
@MainActor protocol TelegramWebSessionsProvider: AnyObject {
    var accountID: Int64 { get }
    func load(receive: @escaping @MainActor (Result<TelegramWebSessionsSnapshot, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest
    func apply(_ change: TelegramWebSessionChange, expected: TelegramWebSessionsSnapshot, receive: @escaping @MainActor (Result<Void, TelegramSessionsError>) -> Void) -> any TelegramSessionsRequest
}
@MainActor public final class TelegramWebSessionsController: ObservableObject {
    public enum MutationStatus: Equatable { case idle, saving, saved, changed, failed, freshReset, uncertain }
    @Published public private(set) var snapshot: TelegramWebSessionsSnapshot?
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public private(set) var mutationStatus: MutationStatus = .idle
    @Published public private(set) var contextID = UUID()
    private var provider: (any TelegramWebSessionsProvider)?
    private var read: (any TelegramSessionsRequest)?, write: (any TelegramSessionsRequest)?
    private var readID: UUID?, writeID: UUID?
    private var readDeadline: Task<Void, Never>?, writeDeadline: Task<Void, Never>?
    private var uncertainAccounts: Set<Int64> = []
    public init() {}
    isolated deinit { read?.cancel(); write?.cancel(); readDeadline?.cancel(); writeDeadline?.cancel() }
    func bind(_ provider: (any TelegramWebSessionsProvider)?) { close(); self.provider = provider }
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
    @discardableResult public func apply(_ change: TelegramWebSessionChange, contextID: UUID) -> Bool {
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
