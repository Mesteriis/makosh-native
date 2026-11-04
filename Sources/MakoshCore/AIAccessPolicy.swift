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
