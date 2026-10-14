import Foundation
import Combine
import Postbox
import TelegramCore

public enum TelegramGroupMembershipSection: String, CaseIterable, Sendable { case overview, activeLinks, revokedLinks, requests, history }
public struct TelegramGroupMembershipSnapshot: Equatable, Sendable {
    public let accountID: Int64, peerID: Int64
    public let title: String
    public let basic: Bool, isCreator: Bool, canInvite: Bool, canManageLinks: Bool, canRequests: Bool, canHistory: Bool
    var isValid: Bool {
        telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser
            && telegramManagementPeerID(peerID).map { $0.namespace == (basic ? Namespaces.Peer.CloudGroup : Namespaces.Peer.CloudChannel) } == true
            && !title.isEmpty && title.utf16.count <= 512 && !title.contains("\0") && (!basic || !canHistory)
    }
    func permits(_ section: TelegramGroupMembershipSection) -> Bool {
        switch section { case .overview: true; case .activeLinks, .revokedLinks: canManageLinks; case .requests: canRequests; case .history: canHistory }
    }
}
public enum TelegramGroupMembershipCursor: Equatable, Sendable {
    case links(date: Int32, link: String, seen: Int32)
    case requests(date: Int32, userID: Int64, seen: Int32)
    case history(maxID: Int64)
}
func telegramValidGroupInviteURL(_ raw: String) -> Bool {
    guard !raw.isEmpty, raw.utf8.count <= 2048, !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
          let url = URLComponents(string: raw), url.scheme == "https", ["t.me", "telegram.me"].contains(url.host),
          url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
          url.path == url.percentEncodedPath else { return false }
    let token: String
    if url.path.hasPrefix("/+") { token = String(url.path.dropFirst(2)) }
    else if url.path.hasPrefix("/joinchat/") { token = String(url.path.dropFirst(10)) }
    else { return false }
    return !token.isEmpty && token.utf8.count <= 256 && token.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
}
public struct TelegramGroupInviteLink: Equatable, Identifiable, Sendable {
    public var id: String { link ?? "publicJoinRequests" }
    public let link: String?
    public let adminID: Int64, date: Int32
    public let title: String?
    public let expireDate: Int32?, usageLimit: Int32?, usage: Int32, requested: Int32
    public let requiresApproval: Bool, revoked: Bool, permanent: Bool, paid: Bool
    let origin: TelegramGroupMembershipCursor?
    var isValid: Bool {
        guard let link else { return adminID == 0 && date == 0 && title == nil && !revoked && !paid && origin == nil }
        return telegramValidGroupInviteURL(link) && telegramManagementPeerID(adminID)?.namespace == Namespaces.Peer.CloudUser
            && date > 0 && usage >= 0 && requested >= 0 && (title.map { $0.utf16.count <= 128 && !$0.contains("\0") } ?? true)
            && (expireDate.map { $0 > 0 } ?? true) && (usageLimit.map { $0 > 0 } ?? true)
    }
}
public struct TelegramGroupInviteDraft: Equatable, Sendable {
    public let title: String
    public let expireDate: Int32?, usageLimit: Int32?
    public let requiresApproval: Bool
    public init(title: String, expireDate: Int32?, usageLimit: Int32?, requiresApproval: Bool) {
        self.title = title; self.expireDate = expireDate; self.usageLimit = usageLimit; self.requiresApproval = requiresApproval
    }
    var normalizedTitle: String? { let value = title.trimmingCharacters(in: .whitespaces); return value.isEmpty ? nil : value }
    func isValid(now: Date = Date()) -> Bool {
        title.utf16.count <= 32 && !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && (expireDate.map { Double($0) - now.timeIntervalSince1970 >= 60 } ?? true)
            && (usageLimit.map { $0 > 0 } ?? true) && (!requiresApproval || usageLimit == nil)
    }
}
public struct TelegramGroupJoinRequest: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let title: String, username: String?
    public let date: Int32
    public let about: String?
    let origin: TelegramGroupMembershipCursor?
    var isValid: Bool {
        telegramManagementPeerID(id)?.namespace == Namespaces.Peer.CloudUser && !title.isEmpty && title.utf16.count <= 512
            && !title.contains("\0") && date > 0 && (about.map { $0.utf16.count <= 4096 && !$0.contains("\0") } ?? true)
            && (username.map { $0.utf16.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } ?? true)
    }
}
public struct TelegramGroupAdminEvent: Equatable, Identifiable, Sendable {
    public let id: Int64, actorID: Int64
    public let actor: String, summary: String
    public let date: Int32
    public let previousText: String?, currentText: String?
    public var copyProtected = false
    public var contentUnavailable = false
    public var allowsCopy: Bool { !copyProtected }
    var isValid: Bool {
        id > 0 && date > 0 && telegramManagementPeerID(actorID)?.namespace == Namespaces.Peer.CloudUser
            && !actor.isEmpty && actor.utf16.count <= 512 && !summary.isEmpty && summary.utf16.count <= 8192
            && [previousText, currentText].allSatisfy { $0.map { $0.utf16.count <= 65536 } ?? true }
    }
}
public struct TelegramGroupLinkCreator: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let active: Int32, revoked: Int32
    var isValid: Bool { telegramManagementPeerID(id)?.namespace == Namespaces.Peer.CloudUser && !title.isEmpty && title.utf16.count <= 512 && active >= 0 && revoked >= 0 }
}
public enum TelegramGroupMembershipChange: Equatable, Sendable {
    case invite(TelegramDiscoveredPeer), create(TelegramGroupInviteDraft), revoke(TelegramGroupInviteLink), request(TelegramGroupJoinRequest, approve: Bool)
}
struct TelegramGroupMembershipReceipt: Equatable, Sendable {
    enum Result: Equatable, Sendable { case invited(Int64), created(TelegramGroupInviteLink), revoked(String), processed(Int64, approve: Bool) }
    let accountID: Int64, peerID: Int64
    let result: Result
    func matches(_ change: TelegramGroupMembershipChange, basis: TelegramGroupMembershipSnapshot) -> Bool {
        guard accountID == basis.accountID, peerID == basis.peerID else { return false }
        switch (change, result) {
        case let (.invite(user), .invited(id)): return user.id == id
        case let (.create(draft), .created(link)):
            return link.isValid && link.link != nil && link.adminID == accountID && !link.revoked && !link.permanent && !link.paid
                && link.title == draft.normalizedTitle && link.expireDate == draft.expireDate && link.usageLimit == draft.usageLimit && link.requiresApproval == draft.requiresApproval
        case let (.revoke(link), .revoked(value)): return link.link == value
        case let (.request(request, approve), .processed(id, actual)): return request.id == id && approve == actual
        default: return false
        }
    }
}
struct TelegramGroupMembershipPage: Sendable {
    let snapshot: TelegramGroupMembershipSnapshot
    var links: [TelegramGroupInviteLink] = []
    var requests: [TelegramGroupJoinRequest] = []
    var events: [TelegramGroupAdminEvent] = []
    var creators: [TelegramGroupLinkCreator] = []
    var next: TelegramGroupMembershipCursor?
}
enum TelegramGroupMembershipError: Error { case failed, changed, unavailable, uncertain, privacyLimited }
enum TelegramGroupMembershipEvent { case committing, saved(TelegramGroupMembershipReceipt), failed(TelegramGroupMembershipError) }
@MainActor protocol TelegramGroupMembershipRequest: AnyObject { func cancel() }
@MainActor protocol TelegramGroupMembershipProvider: AnyObject {
    var accountID: Int64 { get }
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?, receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest
    func apply(basis: TelegramGroupMembershipSnapshot, change: TelegramGroupMembershipChange, receive: @escaping @MainActor (TelegramGroupMembershipEvent) -> Bool) -> any TelegramGroupMembershipRequest
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?, historyFilter: TelegramAdminHistoryFilter, receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest
}

@MainActor private final class TelegramUnavailableHistoryRead: TelegramGroupMembershipRequest { func cancel() {} }
extension TelegramGroupMembershipProvider {
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?, historyFilter: TelegramAdminHistoryFilter, receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest {
        guard historyFilter == .all else { receive(.failure(.unavailable)); return TelegramUnavailableHistoryRead() }
        return load(peerID: peerID, page: page, ownerID: ownerID, query: query, cursor: cursor, receive: receive)
    }
}
