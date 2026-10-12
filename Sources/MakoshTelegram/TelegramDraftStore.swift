import Foundation

/// In-memory composer state. The caller owns persistence and actor isolation.
struct TelegramDraftStore: Sendable {
    private struct Key: Hashable, Sendable {
        let accountID: Int64
        let chatID: Int64
        let threadID: Int64?
    }
    private var drafts: [Key: TelegramComposerDraft] = [:]

    /// Retain even the first empty save so delayed restore cannot resurrect text.
    @discardableResult
    mutating func save(_ text: String, accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> TelegramComposerDraft? {
        guard let input = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: text)) else { return nil }
        return save(input: input, accountID: accountID, chatID: chatID, threadID: threadID)
    }

    @discardableResult
    mutating func save(input: TelegramComposerInput, accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> TelegramComposerDraft? {
        let key = Key(accountID: accountID, chatID: chatID, threadID: threadID)
        guard drafts[key]?.forwardCanMutate ?? true else { return nil }
        let schema = threadID != nil ? 6 : drafts[key]?.replyTarget?.quote == nil ? 4 : 5
        guard drafts[key]?.input != input || drafts[key]?.schemaVersion != schema else { return nil }
        let snapshot = TelegramComposerDraft(accountID: accountID, chatID: chatID, input: input, threadID: threadID, replyTarget: drafts[key]?.replyTarget, forwardIntent: drafts[key]?.forwardIntent)
        guard snapshot.isValid else { return nil }
        drafts[key] = snapshot
        return snapshot
    }

    @discardableResult
    mutating func setReplyTarget(_ target: TelegramComposerReplyTarget?, accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> TelegramComposerDraft? {
        guard target?.isValid ?? true else { return nil }
        let key = Key(accountID: accountID, chatID: chatID, threadID: threadID)
        guard drafts[key]?.forwardCanMutate ?? true else { return nil }
        if let current = drafts[key], current.replyTarget == target, current.schemaVersion == (threadID != nil ? 6 : target?.quote == nil ? 4 : 5) { return nil }
        let snapshot = TelegramComposerDraft(accountID: accountID, chatID: chatID, input: drafts[key]?.input ?? .empty, threadID: threadID, replyTarget: target, forwardIntent: drafts[key]?.forwardIntent)
        guard snapshot.isValid else { return nil }
        drafts[key] = snapshot
        return snapshot
    }

    @discardableResult
    mutating func setForwardIntent(_ intent: TelegramComposerForwardIntent?, accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> TelegramComposerDraft? {
        guard intent?.isValid ?? true else { return nil }
        let key = Key(accountID: accountID, chatID: chatID, threadID: threadID)
        guard drafts[key]?.forwardCanMutate ?? true else { return nil }
        if let current = drafts[key], current.forwardIntent == intent, current.schemaVersion == (threadID != nil ? 6 : current.replyTarget?.quote == nil ? 4 : 5) { return nil }
        let snapshot = TelegramComposerDraft(accountID: accountID, chatID: chatID, input: drafts[key]?.input ?? .empty, threadID: threadID,
            replyTarget: drafts[key]?.replyTarget, forwardIntent: intent)
        guard snapshot.isValid else { return nil }
        drafts[key] = snapshot
        return snapshot
    }

    func draft(accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> String {
        snapshot(accountID: accountID,chatID: chatID, threadID: threadID)?.text ?? ""
    }
    func snapshot(accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> TelegramComposerDraft? {
        drafts[Key(accountID: accountID,chatID: chatID, threadID: threadID)]
    }

    /// Compare against the revision captured before the asynchronous read began.
    @discardableResult
    mutating func restore(_ snapshot: TelegramComposerDraft?, accountID: Int64, chatID: Int64, threadID: Int64? = nil,
                          expectedRevision: UUID?) -> Bool {
        let key = Key(accountID: accountID,chatID: chatID, threadID: threadID)
        guard drafts[key]?.revision == expectedRevision else { return false }
        // Missing durable data never deletes a local snapshot or creates a tombstone.
        guard let snapshot else { return drafts[key] == nil }
        guard snapshot.isValid, snapshot.accountID == accountID, snapshot.chatID == chatID, snapshot.threadID == threadID else { return false }
        drafts[key] = snapshot
        return true
    }

    @discardableResult
    mutating func acknowledge(sentText: String, revision: UUID, accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> TelegramComposerDraft? {
        guard let input = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: sentText)) else { return nil }
        return acknowledge(sentInput: input, revision: revision, accountID: accountID, chatID: chatID, threadID: threadID)
    }

    @discardableResult
    mutating func acknowledge(sentInput: TelegramComposerInput, revision: UUID, accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> TelegramComposerDraft? {
        let key = Key(accountID: accountID, chatID: chatID, threadID: threadID)
        guard let current = drafts[key], current.forwardDisposition != .submissionStarted, current.revision == revision, current.input == sentInput,
              (!current.text.isEmpty || current.replyTarget != nil || current.forwardIntent != nil) else { return nil }
        let cleared = TelegramComposerDraft(accountID: accountID, chatID: chatID, input: .empty, threadID: threadID)
        drafts[key] = cleared
        return cleared
    }

    /// Compatibility only; asynchronous senders must capture and pass the revision.
    mutating func acknowledge(sentText: String, accountID: Int64, chatID: Int64, threadID: Int64? = nil) {
        guard let revision = snapshot(accountID: accountID,chatID: chatID, threadID: threadID)?.revision else { return }
        _ = acknowledge(sentText: sentText,revision: revision,accountID: accountID,chatID: chatID, threadID: threadID)
    }
}
