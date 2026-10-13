import Foundation
import Combine
import Postbox
import TelegramCore

struct TelegramRemotePeerQuery: Equatable, Sendable {
    let value: String
    init?(_ raw: String) {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("@") { value.removeFirst() }
        guard !value.isEmpty, value.utf16.count <= 256, !value.hasPrefix("#"), !value.hasPrefix("$") else { return nil }
        self.value = value
    }
}
public struct TelegramDiscoveredPeer: Equatable, Identifiable, Sendable {
    public var id: Int64 { chat.id }
    public let chat: TelegramChat
    public let username: String?
    var isValid: Bool {
        let native = PeerId(chat.id)
        return native.id._internalGetInt64Value() > 0 &&
            [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(native.namespace) &&
            !chat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.title.utf16.count <= 512 &&
            !chat.title.contains("\0") && (username.map { $0.utf16.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } ?? true)
    }
}
func telegramMergeDiscoveredPeers(my: [TelegramDiscoveredPeer], global: [TelegramDiscoveredPeer], excluding: Set<Int64> = []) -> [TelegramDiscoveredPeer]? {
    guard my.count + global.count <= 200, (my + global).allSatisfy(\.isValid) else { return nil }
    var seen = excluding
    return (my + global).filter { seen.insert($0.id).inserted }
}
enum TelegramRemotePeerError: Error { case failed, unavailable, changed }
@MainActor protocol TelegramRemotePeerRequest: AnyObject { func cancel() }
@MainActor protocol TelegramRemotePeerProvider: AnyObject {
    var accountID: Int64 { get }
    func search(query: String, receive: @escaping @MainActor (Result<[TelegramDiscoveredPeer], TelegramRemotePeerError>) -> Void) -> any TelegramRemotePeerRequest
    func resolve(peerID: Int64, receive: @escaping @MainActor (Result<TelegramChat, TelegramRemotePeerError>) -> Void) -> any TelegramRemotePeerRequest
}

@MainActor public final class TelegramRemotePeerSearch: ObservableObject {
    @Published public private(set) var results: [TelegramDiscoveredPeer] = []
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public private(set) var contextID = UUID()
    @Published public private(set) var isResolving = false
    public private(set) var accountID: Int64?
    private var provider: (any TelegramRemotePeerProvider)?
    private var query: String?
    private var readID: UUID?, resolveID: UUID?
    private var read: (any TelegramRemotePeerRequest)?, resolution: (any TelegramRemotePeerRequest)?
    private var debounce: Task<Void, Never>?, deadline: Task<Void, Never>?, resolveDeadline: Task<Void, Never>?
    isolated deinit { debounce?.cancel(); deadline?.cancel(); resolveDeadline?.cancel(); read?.cancel(); resolution?.cancel() }
    func bind(_ provider: (any TelegramRemotePeerProvider)?) {
        cancel(); self.provider = provider; accountID = provider?.accountID; query = nil
    }
    public func search(_ raw: String, enabled: Bool = true) {
        cancel(); query = nil
        guard enabled, let query = TelegramRemotePeerQuery(raw), let provider, provider.accountID == accountID else { return }
        self.query = query.value
        let token = UUID(); readID = token; status = .loading
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.readID == token else { return }
            self.startRead(provider, query: query.value, token: token)
        }
    }
    public func retry() { if let query { search(query) } }
    private func startRead(_ provider: any TelegramRemotePeerProvider, query: String, token: UUID) {
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.readID == token else { return }
            self.readID = nil; self.read?.cancel(); self.read = nil; self.status = .timedOut
        }
        let request = provider.search(query: query) { [weak self] response in
            guard let self, self.readID == token, self.accountID == provider.accountID else { return }
            self.readID = nil; self.deadline?.cancel(); self.deadline = nil; self.read?.cancel(); self.read = nil
            switch response {
            case let .success(peers):
                guard let peers = telegramMergeDiscoveredPeers(my: [], global: peers) else { self.status = .failed; return }
                self.results = peers; self.status = .ready
            case .failure: self.status = .failed
            }
        }
        if readID == token { read = request } else { request.cancel() }
    }
    @discardableResult public func activate(peerID: Int64, contextID: UUID, receive: @escaping @MainActor (TelegramChat) -> Void) -> Bool {
        guard self.contextID == contextID, status == .ready, !isResolving, results.contains(where: { $0.id == peerID }),
              let provider, provider.accountID == accountID else { return false }
        let token = UUID(); resolveID = token; isResolving = true
        resolveDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.resolveID == token else { return }
            self.cancelResolution(); self.status = .timedOut
        }
        let request = provider.resolve(peerID: peerID) { [weak self] response in
            guard let self, self.resolveID == token, self.contextID == contextID, self.accountID == provider.accountID else { return }
            self.cancelResolution()
            guard case let .success(chat) = response, chat.id == peerID,
                  TelegramDiscoveredPeer(chat: chat, username: nil).isValid else { self.status = .failed; return }
            receive(chat)
        }
        if resolveID == token { resolution = request } else { request.cancel() }
        return true
    }
    private func cancelResolution() {
        resolveID = nil; resolveDeadline?.cancel(); resolveDeadline = nil; resolution?.cancel(); resolution = nil; isResolving = false
    }
    private func cancel() {
        contextID = UUID(); readID = nil; debounce?.cancel(); debounce = nil; deadline?.cancel(); deadline = nil
        read?.cancel(); read = nil; cancelResolution(); results = []; status = .idle
    }
}
