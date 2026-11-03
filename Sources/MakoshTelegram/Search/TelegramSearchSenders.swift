import Foundation
import Combine
import TelegramCore
import Postbox
import SwiftSignalKit

public struct TelegramSearchSender: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
}

/// Sender suggestions use the current conversation's native members and recent
/// authors. Empty supergroup queries retain the engine's cached-member limit.
@MainActor public final class TelegramSearchSenders: ObservableObject {
    @Published public private(set) var available = false
    @Published public private(set) var candidates: [TelegramSearchSender] = []
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public var query = "" { didSet { if oldValue != query { load() } } }
    private var account: Account?
    private var chatID: Int64?
    private var threadID: Int64?
    private var context = UUID()
    private var requestID: UUID?
    private let membership = MetaDisposable(), request = MetaDisposable()
    private var task: Task<Void, Never>?, deadline: Task<Void, Never>?
    #if DEBUG
    private var synthetic = false
    #endif
    public init() {}
    isolated deinit { task?.cancel(); deadline?.cancel(); membership.dispose(); request.dispose() }

    func bind(account: Account?, chatID: Int64?, threadID: Int64?) {
        cancel(); membership.set(nil); context = UUID()
        self.account = account; self.chatID = chatID; self.threadID = threadID
        available = false; query = ""
        #if DEBUG
        synthetic = false
        #endif
        guard let account, let chatID else { return }
        let context = self.context
        membership.set((telegramSearchSenderMembership(postbox: account.postbox, chatID: chatID) |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self, self.context == context else { return }
            self.available = value
        }))
    }

    public func retry() { load() }

    private func cancel() {
        task?.cancel(); task = nil; deadline?.cancel(); deadline = nil
        request.set(nil); requestID = nil; candidates = []; status = .idle
    }

    private func load() {
        cancel()
        guard available else { return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = self.context, token = UUID()
        requestID = token; status = .loading
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.context == context, self.requestID == token else { return }
            #if DEBUG
            if self.synthetic {
                self.receive([.init(id: 1, title: "Макош QA"), .init(id: 999, title: "Тестовый собеседник")]
                    .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }, token: token)
                return
            }
            #endif
            guard let account = self.account, let chatID = self.chatID else { self.cancel(); return }
            self.deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.requestID == token else { return }
                self.requestID = nil; self.request.set(nil); self.status = .timedOut
            }
            let candidates = telegramSearchSenderCandidates(account: account, chatID: chatID,
                threadID: self.threadID, query: query)
            self.request.set((candidates |> deliverOnMainQueue).start(next: { [weak self] ranked in
                guard let self, self.context == context, self.requestID == token else { return }
                self.receive(ranked, token: token)
            }))
        }
    }

    private func receive(_ values: [TelegramSearchSender], token: UUID) {
        guard requestID == token else { return }
        requestID = nil; deadline?.cancel(); deadline = nil; candidates = values; status = .ready
    }

    #if DEBUG
    func useSyntheticPreview(isGroup: Bool) { cancel(); context = UUID(); synthetic = true; available = isGroup }
    #endif
}

nonisolated func telegramSearchSenderMembership(postbox: Postbox, chatID: Int64) -> Signal<Bool, NoError> {
    return postbox.transaction { transaction -> Bool in
        if transaction.getPeer(PeerId(chatID)) is TelegramGroup { return true }
        if let peer = transaction.getPeer(PeerId(chatID)) as? TelegramChannel,
           case .group = peer.info { return true }
        return false
    }
}

nonisolated func telegramSearchSenderCandidates(account: Account, chatID: Int64, threadID: Int64?, query: String) -> Signal<[TelegramSearchSender], NoError> {
    let members = TelegramEngine(account: account).peers.searchGroupMembers(peerId: PeerId(chatID), query: query)
        |> mapToSignal { peers in account.postbox.transaction { transaction -> [Peer] in
            var values = peers.map { $0._asPeer() }
            if let own = transaction.getPeer(account.peerId), query.isEmpty || telegramPeerTitle(own).localizedCaseInsensitiveContains(query) { values.append(own) }
            if let chat = transaction.getPeer(PeerId(chatID)) as? TelegramChannel, case .group = chat.info,
               query.isEmpty || telegramPeerTitle(chat).localizedCaseInsensitiveContains(query) { values.append(chat) }
            return values
        } }
    let history = account.viewTracker.aroundMessageOfInterestHistoryViewForLocation(
        .peer(peerId: PeerId(chatID), threadId: threadID), count: 100, trackHoles: false) |> take(1)
    return combineLatest(members, history) |> take(1) |> map { peers, history in
        let recent = history.0.entries.reversed().compactMap { $0.message.author?.id }
        var unique: Set<Int64> = []
        let recentPeers = history.0.entries.reversed().compactMap { $0.message.author }.filter {
            query.isEmpty || telegramPeerTitle($0).localizedCaseInsensitiveContains(query)
        }
        let ranked = (peers + recentPeers).sorted { lhs, rhs in
            if lhs.id == account.peerId { return rhs.id != account.peerId }
            if rhs.id == account.peerId { return false }
            let a = recent.firstIndex(of: lhs.id) ?? Int.max, b = recent.firstIndex(of: rhs.id) ?? Int.max
            return a != b ? a < b : telegramPeerTitle(lhs).localizedStandardCompare(telegramPeerTitle(rhs)) == .orderedAscending
        }.compactMap { peer -> TelegramSearchSender? in
            guard unique.insert(peer.id.toInt64()).inserted else { return nil }
            return TelegramSearchSender(id: peer.id.toInt64(), title: telegramPeerTitle(peer))
        }
        return ranked
    }
}
