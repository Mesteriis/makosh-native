import Foundation
import Combine

struct TelegramPeerMemberPage: Equatable, Sendable {
    let snapshot: TelegramPeerManagementSnapshot
    let members: [TelegramPeerMember]
    let nextOffset: Int32?
}

enum TelegramPeerManagementError: Error, Equatable, Sendable { case unavailable, changed, failed, uncertain }
@MainActor protocol TelegramPeerManagementRequest: AnyObject { func cancel() }
@MainActor protocol TelegramPeerManagementProvider: AnyObject {
    var accountID: Int64 { get }
    func load(peerID: Int64, category: TelegramPeerMemberCategory?, query: String, offset: Int32,
        receive: @escaping @MainActor (Result<TelegramPeerMemberPage, TelegramPeerManagementError>) -> Void) -> any TelegramPeerManagementRequest
    func apply(peerID: Int64, change: TelegramPeerChange,
        receive: @escaping @MainActor (Result<Void, TelegramPeerManagementError>) -> Void) -> any TelegramPeerManagementRequest
}

@MainActor public final class TelegramPeerManagementController: ObservableObject {
    public enum MutationStatus: Equatable { case idle, saving, saved, failed, changed, uncertain }
    @Published public private(set) var snapshot: TelegramPeerManagementSnapshot?
    @Published public private(set) var members: [TelegramPeerMember] = []
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public private(set) var mutationStatus: MutationStatus = .idle
    @Published public private(set) var category: TelegramPeerMemberCategory?
    @Published public private(set) var query = ""
    @Published public private(set) var contextID = UUID()
    public private(set) var peerID: Int64?
    public private(set) var nextOffset: Int32?
    public var canLoadMore: Bool { nextOffset != nil && status != .loading }
    private var provider: (any TelegramPeerManagementProvider)?
    private var read: (any TelegramPeerManagementRequest)?, mutation: (any TelegramPeerManagementRequest)?
    private var readID: UUID?, mutationID: UUID?
    private var readDeadline: Task<Void, Never>?, mutationDeadline: Task<Void, Never>?
    private struct Destination: Hashable { let accountID: Int64, peerID: Int64 }
    private var uncertain: Set<Destination> = []
    public init() {}
    isolated deinit { read?.cancel(); mutation?.cancel(); readDeadline?.cancel(); mutationDeadline?.cancel() }
    func bind(_ provider: (any TelegramPeerManagementProvider)?) { close(); self.provider = provider }
    public func open(peerID: Int64) {
        close(); self.peerID = peerID
        if let accountID = provider?.accountID, uncertain.contains(.init(accountID: accountID, peerID: peerID)) { mutationStatus = .uncertain }
        load(offset: 0)
    }
    public func close() {
        if mutationStatus == .saving, let accountID = provider?.accountID, let peerID {
            uncertain.insert(.init(accountID: accountID, peerID: peerID))
        }
        readID = nil; mutationID = nil; contextID = UUID()
        read?.cancel(); read = nil; mutation?.cancel(); mutation = nil
        readDeadline?.cancel(); readDeadline = nil; mutationDeadline?.cancel(); mutationDeadline = nil
        snapshot = nil; members = []; peerID = nil; nextOffset = nil; category = nil; query = ""
        status = .idle; mutationStatus = .idle
    }
    public func show(_ category: TelegramPeerMemberCategory?, query: String = "") {
        guard mutationStatus != .saving, snapshot.map({ snapshot in category.map(snapshot.permits) ?? true }) == true else { return }
        contextID = UUID(); self.category = category
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        members = []; nextOffset = nil; load(offset: 0)
    }
    public func refresh() { guard mutationStatus != .saving else { return }; load(offset: 0, reconcile: true) }
    public func loadMore() { guard canLoadMore, let nextOffset else { return }; load(offset: nextOffset) }
    private func load(offset: Int32, reconcile: Bool = false) {
        readID = nil; read?.cancel(); read = nil; readDeadline?.cancel(); readDeadline = nil
        guard let provider, let peerID else { status = .failed; return }
        let token = UUID(), context = contextID, accountID = provider.accountID
        readID = token; status = .loading
        readDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.readID == token else { return }
            self.readID = nil; self.read?.cancel(); self.read = nil; self.status = .timedOut
        }
        let request = provider.load(peerID: peerID, category: category, query: query, offset: offset) { [weak self] result in
            guard let self, self.readID == token, self.contextID == context else { return }
            self.readID = nil; self.readDeadline?.cancel(); self.readDeadline = nil
            switch result {
            case .failure: self.status = .failed
            case let .success(page):
                guard page.snapshot.accountID == accountID, page.snapshot.peerID == peerID,
                      page.members.count <= (page.snapshot.basicGroup ? 1_000 : 64),
                      page.members.allSatisfy({ telegramManagementPeerID($0.id) != nil }),
                      page.nextOffset.map({ $0 > offset && Int64($0) <= Int64(offset) + 64 }) ?? true else { self.status = .failed; return }
                self.snapshot = page.snapshot
                if offset == 0 { self.members = [] }
                var seen = Set(self.members.map(\.id))
                self.members += page.members.filter { seen.insert($0.id).inserted }
                self.nextOffset = page.nextOffset; self.status = .ready
                if reconcile, self.mutationStatus == .uncertain {
                    self.uncertain.remove(.init(accountID: accountID, peerID: peerID)); self.mutationStatus = .idle
                }
            }
        }
        if readID == token { read = request } else { request.cancel() }
    }
    @discardableResult public func apply(_ change: TelegramPeerChange, contextID: UUID) -> Bool {
        guard self.contextID == contextID, status == .ready, mutationStatus != .saving, mutationStatus != .uncertain,
              let provider, let snapshot, let peerID, snapshot.accountID == provider.accountID,
              snapshot.peerID == peerID, snapshot.permits(change) else { return false }
        switch change {
        case let .administrator(member, _, _), let .restriction(member, _, _):
            guard members.contains(member) else { return false }
        default: break
        }
        let token = UUID(); mutationID = token; mutationStatus = .saving
        mutationDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.mutationID == token else { return }; self.timeoutMutation()
        }
        let request = provider.apply(peerID: peerID, change: change) { [weak self] result in
            guard let self, self.mutationID == token, self.contextID == contextID else { return }
            self.mutationID = nil; self.mutationDeadline?.cancel(); self.mutationDeadline = nil
            self.mutation?.cancel(); self.mutation = nil
            switch result {
            case .success: self.mutationStatus = .saved; self.load(offset: 0)
            case .failure(.changed): self.mutationStatus = .changed; self.load(offset: 0)
            case .failure(.uncertain):
                self.uncertain.insert(.init(accountID: provider.accountID, peerID: peerID)); self.mutationStatus = .uncertain
            case .failure: self.mutationStatus = .failed
            }
        }
        if mutationID == token { mutation = request } else { request.cancel() }
        return true
    }
    func timeoutMutation() {
        guard mutationID != nil, let accountID = provider?.accountID, let peerID else { return }
        mutationID = nil; mutation?.cancel(); mutation = nil; mutationDeadline?.cancel(); mutationDeadline = nil
        uncertain.insert(.init(accountID: accountID, peerID: peerID)); mutationStatus = .uncertain
    }
}
