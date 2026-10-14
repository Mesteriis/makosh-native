import Foundation
import Combine
import TelegramCore

@MainActor public final class TelegramGroupMembershipController: ObservableObject {
    public enum Phase: Equatable { case idle, validating, committing, saved, changed, failed, privacyLimited, uncertain }
    @Published public private(set) var snapshot: TelegramGroupMembershipSnapshot?
    @Published public private(set) var links: [TelegramGroupInviteLink] = []
    @Published public private(set) var requests: [TelegramGroupJoinRequest] = []
    @Published public private(set) var events: [TelegramGroupAdminEvent] = []
    @Published public private(set) var creators: [TelegramGroupLinkCreator] = []
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var page: TelegramGroupMembershipSection = .overview
    @Published public private(set) var contextID = UUID()
    @Published public private(set) var lastCreatedLink: TelegramGroupInviteLink?
    @Published public private(set) var lastSubmittedChange: TelegramGroupMembershipChange?
    public private(set) var peerID: Int64?, ownerID: Int64?
    public private(set) var query = ""
    @Published public private(set) var historyFilter = TelegramAdminHistoryFilter.all
    @discardableResult public func filterHistory(_ filter: TelegramAdminHistoryFilter, contextID: UUID) -> Bool {
        guard contextID == self.contextID, page == .history, snapshot?.canHistory == true, !isBusy, filter.isValid else { return false }
        historyFilter = filter; self.contextID = UUID(); events = []; next = nil; load(cursor: nil); return true
    }
    public private(set) var next: TelegramGroupMembershipCursor?
    public var accountID: Int64? { provider?.accountID }
    public var isBusy: Bool { phase == .validating || phase == .committing }
    public var canLoadMore: Bool { next != nil && status == .ready && !isBusy }
    public func canSubmit(_ change: TelegramGroupMembershipChange) -> Bool {
        guard let snapshot, status == .ready, !isBusy, phase != .uncertain else { return false }
        return permits(change, basis: snapshot)
    }
    private var provider: (any TelegramGroupMembershipProvider)?
    private var read: (any TelegramGroupMembershipRequest)?, write: (any TelegramGroupMembershipRequest)?
    private var readID: UUID?, writeID: UUID?
    private var readDeadline: Task<Void, Never>?, writeDeadline: Task<Void, Never>?
    private struct Destination: Hashable { let accountID: Int64, peerID: Int64 }
    private var uncertain: [Destination: TelegramGroupMembershipChange] = [:]
    public init() {}
    isolated deinit { read?.cancel(); write?.cancel(); readDeadline?.cancel(); writeDeadline?.cancel() }
    func bind(_ provider: (any TelegramGroupMembershipProvider)?) { close(); self.provider = provider }
    public func open(peerID: Int64) {
        close()
        guard let id = telegramManagementPeerID(peerID), id.namespace == Namespaces.Peer.CloudGroup || id.namespace == Namespaces.Peer.CloudChannel,
              let provider else { status = .failed; return }
        self.peerID = peerID; ownerID = provider.accountID
        if let change = uncertain[.init(accountID: provider.accountID, peerID: peerID)] { phase = .uncertain; lastSubmittedChange = change }
        load(cursor: nil)
    }
    public func close() {
        if phase == .committing { retainUncertain() }
        readID = nil; writeID = nil; contextID = UUID()
        read?.cancel(); write?.cancel(); read = nil; write = nil
        readDeadline?.cancel(); writeDeadline?.cancel(); readDeadline = nil; writeDeadline = nil
        snapshot = nil; links = []; requests = []; events = []; creators = []; peerID = nil; ownerID = nil
        query = ""; historyFilter = .all; next = nil; status = .idle; phase = .idle; page = .overview; lastCreatedLink = nil; lastSubmittedChange = nil
    }
    @discardableResult public func show(_ page: TelegramGroupMembershipSection, query: String = "") -> Bool {
        guard !isBusy, snapshot?.permits(page) == true, validQuery(query) else { return false }
        contextID = UUID(); self.page = page; self.query = query.trimmingCharacters(in: .whitespaces)
        links = []; requests = []; events = []; creators = []; next = nil; load(cursor: nil); return true
    }
    @discardableResult public func selectOwner(_ id: Int64) -> Bool {
        guard !isBusy, snapshot?.isCreator == true, snapshot?.canManageLinks == true,
              creators.contains(where: { $0.id == id }) || id == accountID, page == .activeLinks || page == .revokedLinks else { return false }
        ownerID = id; contextID = UUID(); links = []; next = nil; load(cursor: nil); return true
    }
    public func refresh() {
        guard !isBusy else { return }
        contextID = UUID()
        // Reopen the relevant fresh state before allowing a new explicit action;
        // this never replays the submitted mutation or claims remote rollback.
        if phase == .uncertain, let lastSubmittedChange {
            switch lastSubmittedChange {
            case .create: page = .activeLinks; ownerID = accountID; query = ""
            case let .revoke(link): page = .activeLinks; ownerID = link.adminID; query = ""
            case .request: page = .requests; query = ""
            case .invite: page = .overview
            }
        }
        load(cursor: nil, reconcile: true)
    }
    public func loadMore() { guard canLoadMore, let next else { return }; load(cursor: next) }
    private func validQuery(_ value: String) -> Bool {
        value.utf16.count <= 255 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private func load(cursor: TelegramGroupMembershipCursor?, reconcile: Bool = false) {
        readID = nil; read?.cancel(); read = nil; readDeadline?.cancel(); readDeadline = nil
        guard let provider, let peerID else { status = .failed; return }
        let token = UUID(), context = contextID, section = page, owner = ownerID
        readID = token; status = .loading
        readDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.readID == token else { return }
            self.readID = nil; self.read?.cancel(); self.read = nil; self.status = .timedOut
        }
        let filter = section == .history ? historyFilter : .all
        let request = provider.load(peerID: peerID, page: section, ownerID: owner, query: query, cursor: cursor, historyFilter: filter) { [weak self] result in
            guard let self, self.readID == token, self.contextID == context, self.accountID == provider.accountID else { return }
            self.readID = nil; self.readDeadline?.cancel(); self.readDeadline = nil; self.read?.cancel(); self.read = nil
            guard case let .success(value) = result, value.snapshot.accountID == provider.accountID, value.snapshot.peerID == peerID,
                  self.admit(value, section: section, owner: owner, cursor: cursor) else { self.status = .failed; return }
            self.snapshot = value.snapshot
            if cursor == nil { self.links = []; self.requests = []; self.events = [] }
            self.links += value.links; self.requests += value.requests; self.events += value.events; self.creators = value.creators
            self.next = value.next; self.status = .ready
            if reconcile {
                self.uncertain.removeValue(forKey: .init(accountID: provider.accountID, peerID: peerID)); self.phase = .idle
            }
        }
        if readID == token { read = request } else { request.cancel() }
    }
    private func admit(_ value: TelegramGroupMembershipPage, section: TelegramGroupMembershipSection, owner: Int64?, cursor: TelegramGroupMembershipCursor?) -> Bool {
        guard value.snapshot.isValid, value.snapshot.permits(section), value.links.count <= 50, value.requests.count <= 50, value.events.count <= 50,
              value.creators.count <= 1000, value.creators.allSatisfy(\.isValid), Set(value.creators.map(\.id)).count == value.creators.count,
              value.links.allSatisfy(\.isValid), value.requests.allSatisfy(\.isValid), value.events.allSatisfy(\.isValid),
              Set(value.links.map(\.id)).count == value.links.count, Set(value.requests.map(\.id)).count == value.requests.count,
              Set(value.events.map(\.id)).count == value.events.count else { return false }
        if cursor != nil {
            guard value.snapshot == snapshot, links.count + requests.count + events.count + value.links.count + value.requests.count + value.events.count <= 10_000,
                  Set(links.map(\.id)).isDisjoint(with: value.links.map(\.id)), Set(requests.map(\.id)).isDisjoint(with: value.requests.map(\.id)),
                  Set(events.map(\.id)).isDisjoint(with: value.events.map(\.id)) else { return false }
        }
        switch section {
        case .overview: return value.links.isEmpty && value.requests.isEmpty && value.events.isEmpty && value.next == nil
        case .activeLinks, .revokedLinks:
            guard value.requests.isEmpty, value.events.isEmpty,
                  value.links.allSatisfy({ $0.link == nil || ($0.adminID == (owner ?? accountID) && $0.revoked == (section == .revokedLinks) && $0.origin == cursor) }) else { return false }
        case .requests:
            guard value.links.isEmpty, value.events.isEmpty, value.requests.allSatisfy({ $0.origin == cursor && $0.id != accountID }) else { return false }
        case .history:
            guard value.links.isEmpty, value.requests.isEmpty,
                  historyFilter.adminIDs.isEmpty || value.events.allSatisfy({ historyFilter.adminIDs.contains($0.actorID) }) else { return false }
            for pair in zip(value.events, value.events.dropFirst()) { if pair.0.id <= pair.1.id { return false } }
            if case let .history(maxID) = cursor, value.events.first.map({ $0.id >= maxID }) == true { return false }
        }
        guard let next = value.next else { return true }
        switch (section, next) {
        case let (.activeLinks, .links(date, link, seen)), let (.revokedLinks, .links(date, link, seen)):
            guard let last = value.links.last, last.link == link, last.date == date else { return false }
            if let cursor { guard case let .links(previousDate, previousLink, previousSeen) = cursor, date <= previousDate, link != previousLink,
                Int64(seen) == Int64(previousSeen) + Int64(value.links.count) else { return false } }
            else if seen != value.links.count { return false }
        case let (.requests, .requests(date, userID, seen)):
            guard let last = value.requests.last, last.id == userID, last.date == date else { return false }
            if let cursor { guard case let .requests(previousDate, previousID, previousSeen) = cursor, date <= previousDate, userID != previousID,
                Int64(seen) == Int64(previousSeen) + Int64(value.requests.count) else { return false } }
            else if seen != value.requests.count { return false }
        case let (.history, .history(maxID)):
            guard value.events.count == 50, value.events.last?.id == maxID, maxID > 0 else { return false }
            if let cursor { guard case let .history(previous) = cursor, maxID < previous else { return false } }
        default: return false
        }
        return true
    }
    func permits(_ change: TelegramGroupMembershipChange, basis: TelegramGroupMembershipSnapshot) -> Bool {
        switch change {
        case let .invite(peer):
            return basis.canInvite && peer.isValid && telegramManagementPeerID(peer.id)?.namespace == Namespaces.Peer.CloudUser && peer.id != basis.accountID
        case let .create(draft): return basis.canManageLinks && draft.isValid()
        case let .revoke(link): return basis.canManageLinks && page == .activeLinks && link.link != nil && !link.revoked && links.contains(link)
            && (link.adminID == basis.accountID || basis.isCreator)
        case let .request(request, _): return basis.canRequests && page == .requests && requests.contains(request)
        }
    }
    @discardableResult public func apply(_ change: TelegramGroupMembershipChange, basis: TelegramGroupMembershipSnapshot, contextID: UUID) -> Bool {
        guard contextID == self.contextID, status == .ready, !isBusy, phase != .uncertain, let provider,
              snapshot == basis, basis.isValid, basis.accountID == provider.accountID, basis.peerID == peerID, permits(change, basis: basis) else { return false }
        let token = UUID(); writeID = token; phase = .validating; lastSubmittedChange = change; lastCreatedLink = nil
        writeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.writeID == token else { return }; self.timeoutMutation()
        }
        let request = provider.apply(basis: basis, change: change) { [weak self] event in
            guard let self, self.writeID == token, self.contextID == contextID, self.accountID == basis.accountID else { return false }
            switch event {
            case .committing: guard self.phase == .validating else { return false }; self.phase = .committing
            case let .saved(receipt):
                guard self.phase == .committing, receipt.matches(change, basis: basis) else { self.markUncertain(); return true }
                if case let .created(link) = receipt.result {
                    self.lastCreatedLink = link; self.ownerID = basis.accountID; self.page = .activeLinks; self.query = ""
                }
                self.finish(.saved); self.load(cursor: nil)
            case .failed(.privacyLimited): self.finish(.privacyLimited)
            case .failed(.changed): if self.phase == .committing { self.markUncertain() } else { self.finish(.changed) }
            case .failed(.uncertain): self.markUncertain()
            case .failed: if self.phase == .committing { self.markUncertain() } else { self.finish(.failed) }
            }
            return true
        }
        if writeID == token { write = request } else { request.cancel() }
        return true
    }
    public func cancelValidation() { guard phase == .validating else { return }; finish(.idle); lastSubmittedChange = nil }
    private func retainUncertain() {
        if let accountID, let peerID, let lastSubmittedChange { uncertain[.init(accountID: accountID, peerID: peerID)] = lastSubmittedChange }
    }
    private func finish(_ phase: Phase) {
        writeID = nil; write?.cancel(); write = nil; writeDeadline?.cancel(); writeDeadline = nil; self.phase = phase
    }
    private func markUncertain() { retainUncertain(); finish(.uncertain) }
    func timeoutMutation() { guard writeID != nil else { return }; if phase == .committing { markUncertain() } else { finish(.failed) } }
}
