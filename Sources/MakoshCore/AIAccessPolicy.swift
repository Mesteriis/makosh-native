import Foundation

/// A source the user may make available to the AI domain. Every scope is
/// disabled until explicitly enabled.
public enum AIAccessScope: Codable, Hashable, Sendable {
    case conversation(service: String, accountID: String, conversationID: String)
    case mailAccount(accountID: String)

    var fields: [String] {
        switch self {
        case .conversation(let service, let accountID, let conversationID): ["conversation", service, accountID, conversationID]
        case .mailAccount(let accountID): ["mail-account", accountID]
        }
    }
    var isValid: Bool { fields.dropFirst().allSatisfy { !$0.isEmpty && $0.utf8.count <= 1024 } }
}

/// Encrypted archive row: the scope travels inside the ciphertext so a
/// backup validator can recompute the lookup token.
struct AIAccessPolicyRecord: Codable {
    let scope: AIAccessScope
    let enabled: Bool
}

/// Per-contact AI access. `inherit` leaves the decision to the chat or
/// mailbox flag, `forbidden` closes the contact everywhere, and `allowed`
/// never opens a disabled chat or mailbox.
public enum AIContactAccess: String, Codable, Sendable { case inherit, allowed, forbidden }

/// One message or letter version offered to the AI index. Sources never
/// filter by access; the indexer decides admission.
public struct AIIndexItem: Sendable, Equatable {
    public let sequence: Int64
    public let identity: MessageArchiveIdentity
    public let scope: AIAccessScope
    public let author: ServiceIdentity?
    public let isOutgoing: Bool
    public let date: Date
    public let title: String
    public let text: String
    public let removed: Bool
    public init(
        sequence: Int64, identity: MessageArchiveIdentity, scope: AIAccessScope, author: ServiceIdentity?, isOutgoing: Bool, date: Date,
        title: String, text: String, removed: Bool
    ) {
        self.sequence = sequence; self.identity = identity; self.scope = scope; self.author = author; self.isOutgoing = isOutgoing
        self.date = date; self.title = title; self.text = text; self.removed = removed
    }
}

/// A journal the AI indexer follows with its own cursor. `after` is
/// exclusive and results are ordered by ascending sequence.
public protocol AIIndexSource: Sendable {
    var name: String { get }
    func items(after sequence: Int64, limit: Int) async throws -> [AIIndexItem]
    func items(in scope: AIAccessScope, after sequence: Int64, limit: Int) async throws -> [AIIndexItem]
}
