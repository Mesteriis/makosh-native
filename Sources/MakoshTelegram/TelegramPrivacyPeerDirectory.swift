import Foundation
import Combine

public struct TelegramPrivacyPeerDirectory: Equatable, Sendable {
    public let accountID: Int64
    public let candidates: [TelegramPrivacyPeer]
    public let existing: [TelegramPrivacyPeer]
    public let hasMore: Bool
    public init(accountID: Int64, candidates: [TelegramPrivacyPeer], existing: [TelegramPrivacyPeer], hasMore: Bool) {
        self.accountID = accountID; self.candidates = candidates; self.existing = existing; self.hasMore = hasMore
    }
}
@MainActor public final class TelegramPrivacyPeerDirectoryController: ObservableObject {
    @Published public private(set) var result: TelegramPrivacyPeerDirectory?
    @Published public private(set) var status: TelegramSearchStatus = .idle
    public init() {}
    private var provider: (any TelegramPrivacyProvider)?
    private var request: (any TelegramPrivacyRequest)?
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    isolated deinit { request?.cancel(); deadline?.cancel() }
    func bind(_ provider: (any TelegramPrivacyProvider)?) { close(); self.provider = provider }
    public func close() {
        generation = UUID(); request?.cancel(); request = nil; deadline?.cancel(); deadline = nil
        result = nil; status = .idle
    }
    public func search(query: String, include: [TelegramPrivacyPeerID]) {
        close()
        guard let provider, query.count <= 128, include.count <= 4096,
              include.allSatisfy({ $0.rawID > 0 }), Set(include).count == include.count else { status = .failed; return }
        let token = generation, account = provider.accountID
        status = .loading
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == token else { return }
            self.close(); self.status = .timedOut
        }
        let lease = provider.peers(query: query, include: include) { [weak self] value in
            guard let self, self.generation == token else { return }
            self.generation = UUID(); self.deadline?.cancel(); self.deadline = nil; self.request?.cancel(); self.request = nil
            switch value {
            case .failure: self.status = .failed
            case let .success(directory):
                func valid(_ peers: [TelegramPrivacyPeer], limit: Int) -> Bool {
                    peers.count <= limit && Set(peers.map(\.id)).count == peers.count
                        && peers.allSatisfy { $0.id.rawID > 0 && !$0.title.isEmpty && $0.title.count <= 512 }
                }
                guard directory.accountID == account, valid(directory.candidates, limit: 200), valid(directory.existing, limit: 4096),
                      Set(directory.existing.map(\.id)).isSubset(of: Set(include)) else { self.status = .failed; return }
                self.result = directory; self.status = .ready
            }
        }
        if generation == token { request = lease } else { lease.cancel() }
    }
}
