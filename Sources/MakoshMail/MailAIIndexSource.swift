import Foundation
import MakoshCore

/// AI index source over retained mail letter versions. The mailbox flag is
/// the account; authors map to the dossier identity used when a letter is
/// linked to a contact (`mail`, account, lowercased sender).
public struct MailAIIndexSource: AIIndexSource {
    public let name = "mail"
    private let repository: MailRepository

    public init(repository: MailRepository) { self.repository = repository }

    public func items(after sequence: Int64, limit: Int) async throws -> [AIIndexItem] {
        try await items(accountID: nil, after: sequence, limit: limit)
    }

    public func items(in scope: AIAccessScope, after sequence: Int64, limit: Int) async throws -> [AIIndexItem] {
        guard case .mailAccount(let accountID) = scope else { return [] }
        return try await items(accountID: accountID, after: sequence, limit: limit)
    }

    private func items(accountID: String?, after sequence: Int64, limit: Int) async throws -> [AIIndexItem] {
        let versions = try await repository.versions(accountID: accountID, after: sequence, limit: limit)
        let addresses = Dictionary(
            try await repository.snapshot().accounts.map { ($0.id, $0.email.lowercased()) }, uniquingKeysWith: { first, _ in first })
        return versions.map { version in
            let letter = version.letter, account = letter.key.accountID, sender = letter.sender.lowercased()
            let text = letter.text ?? letter.html.map(MIME.stripHTML) ?? ""
            return AIIndexItem(
                sequence: version.id,
                identity: MessageArchiveIdentity(service: "mail", accountID: account, conversationID: letter.key.folder, messageID: letter.id),
                scope: .mailAccount(accountID: account), author: ServiceIdentity(service: "mail", accountID: account, externalID: sender),
                isOutgoing: addresses[account] == sender, date: letter.date, title: letter.subject,
                text: letter.removedFromSource == true ? "" : text, removed: letter.removedFromSource == true)
        }
    }
}
