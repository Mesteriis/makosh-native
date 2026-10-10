/// In-memory composer text, scoped to one account and one conversation.
/// The caller owns persistence and actor isolation; this value has no side effects.
struct TelegramDraftStore: Sendable {
    private struct Key: Hashable, Sendable {
        let accountID: Int64
        let chatID: Int64
    }
    private var drafts: [Key: String] = [:]

    mutating func save(_ text: String, accountID: Int64, chatID: Int64) {
        let key = Key(accountID: accountID, chatID: chatID)
        drafts[key] = text.isEmpty ? nil : text
    }

    func draft(accountID: Int64, chatID: Int64) -> String {
        drafts[Key(accountID: accountID, chatID: chatID)] ?? ""
    }

    mutating func acknowledge(sentText: String, accountID: Int64, chatID: Int64) {
        let key = Key(accountID: accountID, chatID: chatID)
        // A delayed acknowledgement must not clear text edited after submission.
        // Compare exact bytes so normalization-only edits are retained as well.
        if let current = drafts[key], current.utf8.elementsEqual(sentText.utf8) {
            drafts.removeValue(forKey: key)
        }
    }
}
