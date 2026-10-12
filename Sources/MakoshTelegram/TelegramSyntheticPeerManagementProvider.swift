#if DEBUG
import Foundation

@MainActor final class TelegramSyntheticPeerManagementProvider: TelegramPeerManagementProvider {
    let accountID: Int64
    private var snapshot: TelegramPeerManagementSnapshot
    private var members: [TelegramPeerMember]
    init(profile: TelegramContactProfile) {
        accountID = profile.accountID
        let basic = profile.kind == .group
        snapshot = .init(accountID: profile.accountID, peerID: profile.peerID, title: profile.displayName, about: profile.about,
            basicGroup: basic, canEditInfo: true, canViewMembers: true, canViewAdministrators: true,
            canRestrict: true, canPromote: true,
            grantableRights: basic ? 1 : TelegramPeerRight.administrators.reduce(0) { $0 | $1.id }, defaultBannedRights: 0)
        members = (1...130).map { number -> TelegramPeerMember in
            let role: TelegramPeerMember.Role = number == 1 ? .creator : (number == 2 ? .administrator : .member)
            return TelegramPeerMember(id: Int64(20000 + number), title: "Участник QA \(number)", role: role,
                adminRights: number == 2 ? 1 : 0, bannedRights: 0, untilDate: 0, rank: number == 2 ? "Редактор" : nil, editable: number != 1)
        }
    }
    func load(peerID: Int64, category: TelegramPeerMemberCategory?, query: String, offset: Int32,
        receive: @escaping @MainActor (Result<TelegramPeerMemberPage, TelegramPeerManagementError>) -> Void) -> any TelegramPeerManagementRequest {
        let request = SyntheticPeerManagementRequest()
        guard peerID == snapshot.peerID, offset >= 0, category.map(snapshot.permits) ?? true else { receive(.failure(.unavailable)); return request }
        let filtered = category.map { category in members.filter { member in
            let included: Bool = switch category {
            case .members: member.role != .removed
            case .administrators: member.role == .creator || member.role == .administrator
            case .restricted: member.role == .restricted
            case .removed: member.role == .removed
            }
            return included && (query.isEmpty || member.title.localizedCaseInsensitiveContains(query))
        } } ?? []
        let start = min(Int(offset), filtered.count), end = min(start + 64, filtered.count)
        receive(.success(.init(snapshot: snapshot, members: Array(filtered[start..<end]), nextOffset: end < filtered.count ? Int32(end) : nil)))
        return request
    }
    func apply(peerID: Int64, change: TelegramPeerChange,
        receive: @escaping @MainActor (Result<Void, TelegramPeerManagementError>) -> Void) -> any TelegramPeerManagementRequest {
        let request = SyntheticPeerManagementRequest()
        guard peerID == snapshot.peerID, snapshot.permits(change) else { receive(.failure(.changed)); return request }
        var title = snapshot.title, about = snapshot.about
        var defaults = snapshot.defaultBannedRights
        switch change {
        case let .permissions(_, value): defaults = value
        case let .title(_, value): title = value
        case let .about(_, value): about = value.isEmpty ? nil : value
        case let .administrator(member, rights, rank):
            guard let index = members.firstIndex(of: member) else { receive(.failure(.changed)); return request }
            members[index] = .init(id: member.id, title: member.title, role: rights == 0 ? .member : .administrator,
                adminRights: rights, bannedRights: 0, untilDate: 0, rank: rank.isEmpty ? nil : rank, editable: true)
        case let .restriction(member, rights, until):
            guard let index = members.firstIndex(of: member) else { receive(.failure(.changed)); return request }
            let removal = TelegramPeerRight.restrictions[0].id
            members[index] = .init(id: member.id, title: member.title, role: rights == 0 ? .member : (rights & removal != 0 ? .removed : .restricted),
                adminRights: 0, bannedRights: rights, untilDate: until, rank: nil, editable: true)
        }
        snapshot = .init(accountID: accountID, peerID: peerID, title: title, about: about, basicGroup: snapshot.basicGroup,
            canEditInfo: snapshot.canEditInfo, canViewMembers: snapshot.canViewMembers, canViewAdministrators: snapshot.canViewAdministrators,
            canRestrict: snapshot.canRestrict, canPromote: snapshot.canPromote, grantableRights: snapshot.grantableRights, defaultBannedRights: defaults)
        receive(.success(())); return request
    }
}
@MainActor private final class SyntheticPeerManagementRequest: TelegramPeerManagementRequest { func cancel() {} }
#endif
