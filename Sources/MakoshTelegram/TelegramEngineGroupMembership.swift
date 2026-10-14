import Foundation
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit

struct TelegramNativeGroupBasis {
    let full: MakoshGroupFullPeer
    let snapshot: TelegramGroupMembershipSnapshot
    let input: Api.InputPeer
}
private func groupUnwrap<T>(_ signal: Signal<T?, NoError>) -> Signal<T, TelegramGroupMembershipError> {
    signal |> castError(TelegramGroupMembershipError.self) |> mapToSignal { value in
        guard let value else { return .fail(.unavailable) }; return .single(value)
    }
}
func telegramNativeGroupBasis(account: Account, peerID: Int64) -> Signal<TelegramNativeGroupBasis, TelegramGroupMembershipError> {
    guard let id = telegramManagementPeerID(peerID), id.namespace == Namespaces.Peer.CloudGroup || id.namespace == Namespaces.Peer.CloudChannel else { return .fail(.unavailable) }
    let response: Signal<Api.messages.ChatFull, TelegramGroupMembershipError>
    if id.namespace == Namespaces.Peer.CloudGroup {
        response = account.network.request(Api.functions.messages.getFullChat(chatId: id.id._internalGetInt64Value()), automaticFloodWait: false) |> mapError { _ in .failed }
    } else {
        response = account.postbox.transaction { transaction -> Signal<Api.messages.ChatFull, TelegramGroupMembershipError> in
            guard let channel = transaction.getPeer(id) as? TelegramChannel, case let .personal(hash) = channel.accessHash, hash != 0 else { return .fail(.unavailable) }
            return account.network.request(Api.functions.channels.getFullChannel(channel: .inputChannel(channelId: id.id._internalGetInt64Value(), accessHash: hash)), automaticFloodWait: false) |> mapError { _ in .failed }
        } |> castError(TelegramGroupMembershipError.self) |> switchToLatest
    }
    return response |> mapToSignal { result in
        guard let full = makoshGroupFullPeer(result, peerId: id),
              let snapshot = telegramGroupMembershipSnapshot(peer: full.peer, accountID: account.peerId.toInt64()),
              let input = telegramGroupInputPeer(full.peer) else { return .fail(.unavailable) }
        return .single(.init(full: full, snapshot: snapshot, input: input))
    }
}
private func groupUserInput(account: Account, id: Int64) -> Signal<Api.InputUser, TelegramGroupMembershipError> {
    if id == account.peerId.toInt64() { return .single(.inputUserSelf) }
    return groupUnwrap(account.postbox.transaction { transaction -> Api.InputUser? in
        guard let nativeID = telegramManagementPeerID(id), nativeID.namespace == Namespaces.Peer.CloudUser,
              let user = transaction.getPeer(nativeID) as? TelegramUser, !user.isDeleted,
              case let .personal(hash) = user.accessHash, hash != 0 else { return nil }
        return .inputUser(userId: nativeID.id._internalGetInt64Value(), accessHash: hash)
    })
}
private func groupCreators(account: Account, basis: TelegramNativeGroupBasis) -> Signal<[TelegramGroupLinkCreator], TelegramGroupMembershipError> {
    guard basis.snapshot.isCreator, basis.snapshot.canManageLinks else { return .single([]) }
    return account.network.request(Api.functions.messages.getAdminsWithInvites(peer: basis.input), automaticFloodWait: false)
        |> mapError { _ in TelegramGroupMembershipError.failed } |> mapToSignal { result in
            groupUnwrap(account.postbox.transaction { transaction -> [TelegramGroupLinkCreator]? in
                switch result {
                case let .chatAdminsWithInvites(admins, users):
                    guard admins.count <= 1000 else { return nil }
                    let ids = admins.map { value -> PeerId in
                        switch value { case let .chatAdminWithInvites(id, _, _): return PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id)) }
                    }
                    guard Set(ids).count == ids.count,
                          let directory = makoshGroupPeerDirectory(transaction: transaction, chats: [], users: users, requiredIds: Set(ids)) else { return nil }
                    var rows: [TelegramGroupLinkCreator] = []
                    for (admin, id) in zip(admins, ids) {
                        guard let peer = directory.peers[id] else { return nil }
                        switch admin {
                        case let .chatAdminWithInvites(_, active, revoked):
                            let row = TelegramGroupLinkCreator(id: id.toInt64(), title: telegramPeerTitle(peer), active: active, revoked: revoked)
                            guard row.isValid else { return nil }; rows.append(row)
                        }
                    }
                    makoshCommitGroupPeerDirectory(transaction: transaction, accountPeerId: account.peerId, directory: directory)
                    return rows
                }
            })
        }
}
private func groupLinks(account: Account, basis: TelegramNativeGroupBasis, ownerID: Int64, revoked: Bool,
    cursor: TelegramGroupMembershipCursor?) -> Signal<TelegramGroupMembershipPage, TelegramGroupMembershipError> {
    guard basis.snapshot.canManageLinks, ownerID == basis.snapshot.accountID || basis.snapshot.isCreator else { return .fail(.unavailable) }
    var date: Int32?, link: String?
    if let cursor {
        guard case let .links(valueDate, valueLink, seen) = cursor, valueDate > 0, telegramValidGroupInviteURL(valueLink), seen > 0, seen < 10_000 else { return .fail(.unavailable) }
        date = valueDate; link = valueLink
    }
    let flags: Int32 = (revoked ? 8 : 0) | (cursor == nil ? 0 : 4)
    return groupUserInput(account: account, id: ownerID) |> mapToSignal { owner in
        account.network.request(Api.functions.messages.getExportedChatInvites(flags: flags, peer: basis.input, adminId: owner,
            offsetDate: date, offsetLink: link, limit: 50), automaticFloodWait: false) |> mapError { _ in TelegramGroupMembershipError.failed }
            |> mapToSignal { response in
                groupUnwrap(account.postbox.transaction { transaction -> TelegramGroupMembershipPage? in
                    guard let page = telegramGroupLinkPage(snapshot: basis.snapshot, ownerID: ownerID, result: response, revoked: revoked, cursor: cursor) else { return nil }
                    switch response {
                    case let .exportedChatInvites(_, _, users):
                        let required = Set(page.links.filter { $0.link != nil }.map { PeerId($0.adminID) })
                        guard let directory = makoshGroupPeerDirectory(transaction: transaction, chats: [], users: users, requiredIds: required) else { return nil }
                        makoshCommitGroupPeerDirectory(transaction: transaction, accountPeerId: account.peerId, directory: directory)
                    }
                    return page
                })
            }
    }
}
private func groupRequests(account: Account, basis: TelegramNativeGroupBasis, query: String,
    cursor: TelegramGroupMembershipCursor?) -> Signal<TelegramGroupMembershipPage, TelegramGroupMembershipError> {
    guard basis.snapshot.canRequests, query.utf16.count <= 255, !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .fail(.unavailable) }
    var date: Int32 = 0
    let offset: Signal<Api.InputUser, TelegramGroupMembershipError>
    if let cursor {
        guard case let .requests(valueDate, id, seen) = cursor, valueDate > 0, seen > 0, seen < 10_000 else { return .fail(.unavailable) }
        date = valueDate; offset = groupUserInput(account: account, id: id)
    } else { offset = .single(.inputUserEmpty) }
    return offset |> mapToSignal { user in
        account.network.request(Api.functions.messages.getChatInviteImporters(flags: 1 | (query.isEmpty ? 0 : 4), peer: basis.input, link: nil,
            q: query.isEmpty ? nil : query, offsetDate: date, offsetUser: user, limit: 50), automaticFloodWait: false)
            |> mapError { _ in TelegramGroupMembershipError.failed } |> mapToSignal { response in
                groupUnwrap(account.postbox.transaction { transaction -> TelegramGroupMembershipPage? in
                    switch response {
                    case let .chatInviteImporters(_, importers, users):
                        let ids = Set(importers.map { value -> PeerId in
                            switch value { case let .chatInviteImporter(_, id, _, _, _): return PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(id)) }
                        })
                        guard let directory = makoshGroupPeerDirectory(transaction: transaction, chats: [], users: users, requiredIds: ids),
                              let page = telegramGroupRequestPage(snapshot: basis.snapshot, result: response, peers: directory.peers, cursor: cursor) else { return nil }
                        makoshCommitGroupPeerDirectory(transaction: transaction, accountPeerId: account.peerId, directory: directory)
                        return page
                    }
                })
            }
    }
}
private func groupHistory(account: Account, basis: TelegramNativeGroupBasis, query: String,
    cursor: TelegramGroupMembershipCursor?, filter: TelegramAdminHistoryFilter) -> Signal<TelegramGroupMembershipPage, TelegramGroupMembershipError> {
    guard filter.isValid, basis.snapshot.canHistory, let channel = basis.full.peer as? TelegramChannel, case let .personal(hash) = channel.accessHash,
          query.utf16.count <= 255, !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .fail(.unavailable) }
    let maxID: Int64
    if let cursor { guard case let .history(id) = cursor, id > 0 else { return .fail(.unavailable) }; maxID = id } else { maxID = 0 }
    return groupUnwrap(account.postbox.transaction { transaction -> [Api.InputUser]? in
        var users: [Api.InputUser] = []
        for id in filter.adminIDs.sorted() {
            guard let peerID = telegramManagementPeerID(id), let user = transaction.getPeer(peerID) as? TelegramUser,
                  case let .personal(value) = user.accessHash, value != 0 else { return nil }
            users.append(.inputUser(userId: peerID.id._internalGetInt64Value(), accessHash: value))
        }
        return users
    }) |> mapToSignal { admins in
        let flags: Int32 = (filter.nativeFlags == nil ? 0 : 1) | (admins.isEmpty ? 0 : 2)
        return account.network.request(Api.functions.channels.getAdminLog(flags: flags,
            channel: .inputChannel(channelId: channel.id.id._internalGetInt64Value(), accessHash: hash), q: query,
            eventsFilter: filter.nativeFlags.map { .channelAdminLogEventsFilter(flags: $0) },
            admins: admins.isEmpty ? nil : admins, maxId: maxID, minId: 0, limit: 50), automaticFloodWait: false)
            |> mapError { _ in TelegramGroupMembershipError.failed }
    } |> mapToSignal { response in
            groupUnwrap(account.postbox.transaction { transaction -> TelegramGroupMembershipPage? in
                switch response {
                case let .adminLogResults(events, chats, users):
                    guard events.count <= 50 else { return nil }
                    var rows: [TelegramGroupAdminEvent] = []
                    var actorIDs = Set(events.map { value -> PeerId in
                        switch value { case let .channelAdminLogEvent(_, _, userID, _): return PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(userID)) }
                    })
                    for event in events {
                        switch event {
                        case let .channelAdminLogEvent(_, _, _, action):
                            guard let presentation = telegramGroupAdminPresentation(action) else { return nil }
                            actorIDs.formUnion(presentation.subjectIDs.map(PeerId.init))
                        }
                    }
                    guard let directory = makoshGroupPeerDirectory(transaction: transaction, chats: chats, users: users, requiredIds: actorIDs) else { return nil }
                    for event in events {
                        switch event {
                        case let .channelAdminLogEvent(id, date, actorID, action):
                            let nativeID = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(actorID))
                            guard filter.adminIDs.isEmpty || filter.adminIDs.contains(nativeID.toInt64()) else { return nil }
                            guard let actor = directory.peers[nativeID], let presentation = telegramGroupAdminPresentation(action) else { return nil }
                            let subjects = presentation.subjectIDs.compactMap { directory.peers[PeerId($0)].map(telegramPeerTitle) }
                            guard subjects.count == presentation.subjectIDs.count else { return nil }
                            let summary = presentation.summary + (subjects.isEmpty ? "" : " · " + subjects.joined(separator: ", "))
                            let row = TelegramGroupAdminEvent(id: id, actorID: nativeID.toInt64(), actor: telegramPeerTitle(actor), summary: summary,
                                date: date, previousText: presentation.previous, currentText: presentation.current)
                            guard row.isValid, id < maxID || maxID == 0, rows.last.map({ $0.id > id }) ?? true else { return nil }; rows.append(row)
                        }
                    }
                    guard let texts = makoshGroupAdminObservations(transaction: transaction, accountPeerId: account.peerId,
                        peerId: channel.id, events: events, peerIsForum: channel.isForum) else { return nil }
                    for index in rows.indices {
                        guard let observation = texts[rows[index].id] else { return nil }
                        let row = rows[index]
                        var updated = TelegramGroupAdminEvent(id: row.id, actorID: row.actorID, actor: row.actor, summary: row.summary, date: row.date,
                            previousText: observation.previous ?? row.previousText, currentText: observation.current ?? row.currentText)
                        updated.copyProtected = observation.copyProtected; updated.contentUnavailable = observation.unavailable; rows[index] = updated
                    }
                    makoshCommitGroupPeerDirectory(transaction: transaction, accountPeerId: account.peerId, directory: directory)
                    var page = TelegramGroupMembershipPage(snapshot: basis.snapshot, events: rows)
                    if rows.count == 50, let last = rows.last { page.next = .history(maxID: last.id) }
                    return page
                }
            })
        }
}
func telegramNativeGroupPage(account: Account, basis: TelegramNativeGroupBasis, page: TelegramGroupMembershipSection,
    ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?, historyFilter: TelegramAdminHistoryFilter = .all) -> Signal<TelegramGroupMembershipPage, TelegramGroupMembershipError> {
    guard basis.snapshot.permits(page) else { return .fail(.unavailable) }
    let result: Signal<TelegramGroupMembershipPage, TelegramGroupMembershipError>
    switch page {
    case .overview: guard cursor == nil else { return .fail(.unavailable) }; result = .single(.init(snapshot: basis.snapshot))
    case .activeLinks, .revokedLinks: result = groupLinks(account: account, basis: basis, ownerID: ownerID ?? basis.snapshot.accountID, revoked: page == .revokedLinks, cursor: cursor)
    case .requests: result = groupRequests(account: account, basis: basis, query: query, cursor: cursor)
    case .history: result = groupHistory(account: account, basis: basis, query: query, cursor: cursor, filter: historyFilter)
    }
    if page == .activeLinks || page == .revokedLinks {
        return result |> mapToSignal { value in groupCreators(account: account, basis: basis) |> map { creators in var value = value; value.creators = creators; return value } }
    }
    return result
}

@MainActor final class TelegramEngineGroupMembershipProvider: TelegramGroupMembershipProvider {
    let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?,
        receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest {
        load(peerID: peerID, page: page, ownerID: ownerID, query: query, cursor: cursor, historyFilter: .all, receive: receive)
    }
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?, historyFilter: TelegramAdminHistoryFilter,
        receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest {
        let request = TelegramNativeGroupRequest(), account = account
        guard historyFilter.isValid, page == .history || historyFilter == .all else { receive(.failure(.unavailable)); return request }
        request.start(telegramNativeGroupBasis(account: account, peerID: peerID) |> mapToSignal { basis in
            telegramNativeGroupPage(account: account, basis: basis, page: page, ownerID: ownerID, query: query, cursor: cursor, historyFilter: historyFilter)
        }, receive: receive)
        return request
    }
    func apply(basis: TelegramGroupMembershipSnapshot, change: TelegramGroupMembershipChange,
        receive: @escaping @MainActor (TelegramGroupMembershipEvent) -> Bool) -> any TelegramGroupMembershipRequest {
        let request = TelegramNativeGroupRequest(), account = account
        guard basis.accountID == accountID, basis.isValid else { _ = receive(.failed(.unavailable)); return request }
        request.start(telegramPrepareGroupChange(account: account, basis: basis, change: change)) { [weak request] result in
            guard let request, !request.stopped else { return }
            guard case let .success(prepared) = result else {
                if case let .failure(error) = result { _ = receive(.failed(error)) }; return
            }
            guard receive(.committing), !request.stopped else { request.cancel(); return }
            request.start(telegramCommitGroupChange(account: account, basis: prepared, change: change)) { [weak request] result in
                guard request?.stopped == false else { return }
                switch result {
                case let .success(receipt):
                    account.viewTracker.forceUpdateCachedPeerData(peerId: PeerId(basis.peerID)); _ = receive(.saved(receipt))
                case let .failure(error): _ = receive(.failed(error))
                }
            }
        }
        return request
    }
}
@MainActor private final class TelegramNativeGroupRequest: TelegramGroupMembershipRequest {
    let disposable = DisposableSet()
    var stopped = false
    func start<T>(_ signal: Signal<T, TelegramGroupMembershipError>, receive: @escaping @MainActor (Result<T, TelegramGroupMembershipError>) -> Void) {
        guard !stopped else { return }; var delivered = false
        disposable.add((signal |> take(1) |> deliverOnMainQueue).start(next: { [weak self] value in
            MainActor.assumeIsolated { guard self?.stopped == false else { return }; delivered = true; receive(.success(value)) }
        }, error: { [weak self] error in MainActor.assumeIsolated { if self?.stopped == false { delivered = true; receive(.failure(error)) } } }, completed: { [weak self] in
            MainActor.assumeIsolated { if !delivered && self?.stopped == false { delivered = true; receive(.failure(.failed)) } }
        }))
    }
    func cancel() { stopped = true; disposable.dispose() }
    isolated deinit { disposable.dispose() }
}
