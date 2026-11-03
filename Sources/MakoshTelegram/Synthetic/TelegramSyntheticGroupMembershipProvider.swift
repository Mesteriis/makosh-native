#if DEBUG
import Foundation
import Postbox
import TelegramCore

@MainActor final class TelegramSyntheticGroupMembershipProvider: TelegramGroupMembershipProvider {
    let accountID: Int64 = 101
    private struct State {
        let snapshot: TelegramGroupMembershipSnapshot
        var links: [TelegramGroupInviteLink]
        var requests: [TelegramGroupJoinRequest]
    }
    private var states: [Int64: State] = [:]
    private func state(_ peerID: Int64) -> State? {
        if let state = states[peerID] { return state }
        guard [4_294_970_002, 8_589_940_003].contains(peerID) else { return nil }
        let basic = PeerId(peerID).namespace == Namespaces.Peer.CloudGroup
        let snapshot = TelegramGroupMembershipSnapshot(accountID: accountID, peerID: peerID, title: basic ? "Synthetic group" : "Synthetic channel",
            basic: basic, isCreator: true, canInvite: true, canManageLinks: true, canRequests: true, canHistory: !basic)
        var links: [TelegramGroupInviteLink] = []
        for n in 1...56 {
            links.append(.init(link: "https://t.me/+Synthetic\(peerID)_\(n)", adminID: n == 56 ? 102 : 101,
                date: Int32(100_000 - n), title: "QA \(n)", expireDate: nil, usageLimit: nil, usage: Int32(n), requested: 0,
                requiresApproval: n == 2, revoked: n >= 53 && n <= 55, permanent: n == 1, paid: false, origin: nil))
        }
        var requests: [TelegramGroupJoinRequest] = []
        for n in 1...55 {
            requests.append(.init(id: Int64(20_000 + n), title: "Synthetic applicant \(n)",
                username: "synthetic_\(n)", date: Int32(100_000 - n), about: "Синтетическая заявка QA", origin: nil))
        }
        let value = State(snapshot: snapshot, links: links, requests: requests); states[peerID] = value; return value
    }
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?,
        receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest {
        load(peerID: peerID, page: page, ownerID: ownerID, query: query, cursor: cursor, historyFilter: .all, receive: receive)
    }
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?, historyFilter: TelegramAdminHistoryFilter,
        receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest {
        let request = SyntheticGroupMembershipRequest()
        guard historyFilter.isValid, page == .history || historyFilter == .all else { receive(.failure(.unavailable)); return request }
        guard let state = state(peerID), state.snapshot.permits(page) else { receive(.failure(.unavailable)); return request }
        if query == "synthetic_failure" { receive(.failure(.failed)); return request }
        var result = TelegramGroupMembershipPage(snapshot: state.snapshot)
        switch page {
        case .overview: break
        case .activeLinks, .revokedLinks:
            let rows = state.links.filter { $0.adminID == (ownerID ?? accountID) && $0.revoked == (page == .revokedLinks) }
            var start = 0
            if case let .links(_, _, seen) = cursor { start = Int(seen) }
            guard start <= rows.count else { receive(.failure(.changed)); return request }
            result.links = rows.dropFirst(start).prefix(50).map { row in
                .init(link: row.link, adminID: row.adminID, date: row.date, title: row.title, expireDate: row.expireDate,
                    usageLimit: row.usageLimit, usage: row.usage, requested: row.requested, requiresApproval: row.requiresApproval,
                    revoked: row.revoked, permanent: row.permanent, paid: row.paid, origin: cursor)
            }
            if start + result.links.count < rows.count, let last = result.links.last, let link = last.link {
                result.next = .links(date: last.date, link: link, seen: Int32(start + result.links.count))
            }
            result.creators = [.init(id: 101, title: "Synthetic owner", active: 52, revoked: 3), .init(id: 102, title: "Synthetic administrator", active: 1, revoked: 0)]
        case .requests:
            let rows = state.requests.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            var start = 0
            if case let .requests(_, _, seen) = cursor { start = Int(seen) }
            guard start <= rows.count else { receive(.failure(.changed)); return request }
            result.requests = rows.dropFirst(start).prefix(50).map { row in
                .init(id: row.id, title: row.title, username: row.username, date: row.date, about: row.about, origin: cursor)
            }
            if start + result.requests.count < rows.count, let last = result.requests.last { result.next = .requests(date: last.date, userID: last.id, seen: Int32(start + result.requests.count)) }
        case .history:
            let descriptions = ["Изменено название", "Сообщение изменено", "Сообщение удалено"]
            result.events = descriptions.enumerated().map { index, title in
                .init(id: Int64(100-index), actorID: 101, actor: "Synthetic owner", summary: title, date: Int32(100_000-index),
                    previousText: index == 1 ? "Текст до правки · QA" : nil, currentText: index > 0 ? "Сохранённый текст · QA" : "Название QA")
            }.filter { row in
                let kind: TelegramAdminEventKind = row.id == 100 ? .info : row.id == 99 ? .editMessages : .deleteMessages
                return (query.isEmpty || row.summary.localizedCaseInsensitiveContains(query))
                    && (historyFilter.kinds?.contains(kind) ?? true)
                    && (historyFilter.adminIDs.isEmpty || historyFilter.adminIDs.contains(row.actorID))
            }
        }
        receive(.success(result)); return request
    }
    func apply(basis: TelegramGroupMembershipSnapshot, change: TelegramGroupMembershipChange,
        receive: @escaping @MainActor (TelegramGroupMembershipEvent) -> Bool) -> any TelegramGroupMembershipRequest {
        let request = SyntheticGroupMembershipRequest()
        guard let state = state(basis.peerID), state.snapshot == basis else { _ = receive(.failed(.changed)); return request }
        request.task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled, var state = self.states[basis.peerID], state.snapshot == basis, receive(.committing) else { return }
            let result: TelegramGroupMembershipReceipt.Result
            switch change {
            case let .invite(peer): result = .invited(peer.id)
            case let .create(draft):
                let link = TelegramGroupInviteLink(link: "https://t.me/+SyntheticCreated_\(UUID().uuidString)", adminID: self.accountID,
                    date: Int32(Date().timeIntervalSince1970), title: draft.normalizedTitle, expireDate: draft.expireDate, usageLimit: draft.usageLimit,
                    usage: 0, requested: 0, requiresApproval: draft.requiresApproval, revoked: false, permanent: false, paid: false, origin: nil)
                state.links.insert(link, at: 0); result = .created(link)
            case let .revoke(row):
                guard let index = state.links.firstIndex(where: { $0.link == row.link }), let link = row.link else { _ = receive(.failed(.uncertain)); return }
                state.links[index] = .init(link: link, adminID: row.adminID, date: row.date, title: row.title, expireDate: row.expireDate, usageLimit: row.usageLimit,
                    usage: row.usage, requested: row.requested, requiresApproval: row.requiresApproval, revoked: true, permanent: row.permanent, paid: row.paid, origin: nil)
                result = .revoked(link)
            case let .request(row, approve):
                guard state.requests.contains(where: { $0.id == row.id }) else { _ = receive(.failed(.uncertain)); return }
                state.requests.removeAll { $0.id == row.id }; result = .processed(row.id, approve: approve)
            }
            self.states[basis.peerID] = state; _ = receive(.saved(.init(accountID: self.accountID, peerID: basis.peerID, result: result)))
        }
        return request
    }
}
@MainActor private final class SyntheticGroupMembershipRequest: TelegramGroupMembershipRequest {
    var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil }
    isolated deinit { task?.cancel() }
}
#endif
