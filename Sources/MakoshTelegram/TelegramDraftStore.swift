import Foundation

/// In-memory composer state. The caller owns persistence and actor isolation.
struct TelegramDraftStore: Sendable {
    private struct Key: Hashable, Sendable {
        let accountID: Int64
        let chatID: Int64
    }
    private var drafts: [Key: TelegramComposerDraft] = [:]

    /// Retain even the first empty save so delayed restore cannot resurrect text.
    @discardableResult
    mutating func save(_ text: String, accountID: Int64, chatID: Int64) -> TelegramComposerDraft? {
        let key = Key(accountID: accountID,chatID: chatID)
        guard drafts[key]?.text.utf8.elementsEqual(text.utf8) != true else { return nil }
        let snapshot = TelegramComposerDraft(accountID: accountID,chatID: chatID,text: text)
        drafts[key] = snapshot
        return snapshot
    }

    func draft(accountID: Int64, chatID: Int64) -> String {
        snapshot(accountID: accountID,chatID: chatID)?.text ?? ""
    }
    func snapshot(accountID: Int64, chatID: Int64) -> TelegramComposerDraft? {
        drafts[Key(accountID: accountID,chatID: chatID)]
    }

    /// Compare against the revision captured before the asynchronous read began.
    @discardableResult
    mutating func restore(_ snapshot: TelegramComposerDraft?, accountID: Int64, chatID: Int64,
                          expectedRevision: UUID?) -> Bool {
        let key = Key(accountID: accountID,chatID: chatID)
        guard drafts[key]?.revision == expectedRevision else { return false }
        // Missing durable data never deletes a local snapshot or creates a tombstone.
        guard let snapshot else { return drafts[key] == nil }
        guard snapshot.isValid, snapshot.accountID == accountID, snapshot.chatID == chatID else { return false }
        drafts[key] = snapshot
        return true
    }

    @discardableResult
    mutating func acknowledge(sentText: String, revision: UUID, accountID: Int64, chatID: Int64) -> TelegramComposerDraft? {
        let key = Key(accountID: accountID,chatID: chatID)
        guard let current = drafts[key], current.revision == revision,
              current.text.utf8.elementsEqual(sentText.utf8), !current.text.isEmpty else { return nil }
        return save("",accountID: accountID,chatID: chatID)
    }

    /// Compatibility only; asynchronous senders must capture and pass the revision.
    mutating func acknowledge(sentText: String, accountID: Int64, chatID: Int64) {
        guard let revision = snapshot(accountID: accountID,chatID: chatID)?.revision else { return }
        _ = acknowledge(sentText: sentText,revision: revision,accountID: accountID,chatID: chatID)
    }
}
