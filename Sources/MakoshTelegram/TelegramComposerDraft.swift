import Foundation
import TelegramCore

struct TelegramComposerReplyTarget: Codable, Equatable, Sendable {
    let peerID: Int64
    let namespace: Int32
    let messageID: Int32
    let threadID: Int64?
    let quote: TelegramReplyQuote?
    init(peerID: Int64, namespace: Int32, messageID: Int32, threadID: Int64? = nil, quote: TelegramReplyQuote? = nil) {
        self.peerID = peerID; self.namespace = namespace; self.messageID = messageID; self.threadID = threadID
        self.quote = quote
    }
    init(source: TelegramMessageActionSource) {
        self.init(peerID: source.peerID, namespace: source.namespace, messageID: source.messageID, threadID: source.threadID, quote: source.replyQuote)
    }
    var isValid: Bool { namespace == Namespaces.Message.Cloud && messageID > 0 }
}

/// A versioned composer snapshot. An empty snapshot without a reply is a
/// retained deletion tombstone; reply-only snapshots are ordinary drafts.
struct TelegramComposerDraft: Codable, Equatable, Sendable {
    static let maximumTextBytes = 64 * 1024
    let schemaVersion: Int
    let accountID: Int64
    let chatID: Int64
    let revision: UUID
    let threadID: Int64?
    let input: TelegramComposerInput
    var text: String { input.formattedText.text }
    let replyTarget: TelegramComposerReplyTarget?
    let forwardIntent: TelegramComposerForwardIntent?
    let forwardDisposition: TelegramComposerForwardDisposition?
    init(accountID: Int64, chatID: Int64, text: String, revision: UUID = UUID(), threadID: Int64? = nil, replyTarget: TelegramComposerReplyTarget? = nil, forwardIntent: TelegramComposerForwardIntent? = nil, forwardDisposition: TelegramComposerForwardDisposition? = nil) {
        self.init(accountID: accountID, chatID: chatID, input: try! TelegramComposerInput(formattedText: TelegramFormattedText(text: text)), revision: revision, threadID: threadID, replyTarget: replyTarget, forwardIntent: forwardIntent, forwardDisposition: forwardDisposition)
    }
    init(accountID: Int64, chatID: Int64, input: TelegramComposerInput, revision: UUID = UUID(), threadID: Int64? = nil, replyTarget: TelegramComposerReplyTarget? = nil, forwardIntent: TelegramComposerForwardIntent? = nil, forwardDisposition: TelegramComposerForwardDisposition? = nil) {
        schemaVersion = threadID != nil ? 6 : replyTarget?.quote == nil ? 4 : 5; self.accountID = accountID; self.chatID = chatID
        self.threadID = threadID
        self.revision = revision; self.input = input; self.replyTarget = replyTarget
        self.forwardIntent = forwardIntent; self.forwardDisposition = forwardDisposition ?? forwardIntent.map { _ in .prepared }
    }
    var isValid: Bool {
        guard (1...6).contains(schemaVersion), text.utf8.count <= Self.maximumTextBytes,
              replyTarget?.isValid ?? true else { return false }
        guard schemaVersion >= 5 || replyTarget?.quote == nil else { return false }
        guard (schemaVersion == 6) == (threadID != nil) else { return false }
        if let threadID {
            guard threadID > 0, threadID <= Int64(Int32.max),
                  replyTarget.map({ $0.peerID == chatID && $0.threadID == threadID }) ?? true else { return false }
        }
        if schemaVersion == 1 && replyTarget != nil { return false }
        guard schemaVersion >= 4 || (forwardIntent == nil && forwardDisposition == nil) else { return false }
        guard let intent = forwardIntent else { return forwardDisposition == nil }
        guard intent.isValid, let disposition = forwardDisposition else { return false }
        if case let .accepted(ids) = disposition { return validForwardQueueIDs(ids) }
        return true
    }
    var forwardCanMutate: Bool { forwardDisposition == nil || forwardDisposition == .prepared }
    func validForwardQueueIDs(_ ids: [TelegramForwardQueueID]) -> Bool {
        guard let intent = forwardIntent, ids.count == intent.sources.count + (text.isEmpty ? 0 : 1),
              !ids.isEmpty, ids.allSatisfy({ $0.peerID == chatID && $0.namespace == Namespaces.Message.Local }) else { return false }
        return Set(ids.map { "\($0.peerID):\($0.namespace):\($0.messageID)" }).count == ids.count
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, accountID, chatID, threadID, revision, text, input, replyTarget, forwardIntent, forwardDisposition }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        accountID = try values.decode(Int64.self, forKey: .accountID)
        chatID = try values.decode(Int64.self, forKey: .chatID)
        threadID = try values.decodeIfPresent(Int64.self, forKey: .threadID)
        revision = try values.decode(UUID.self, forKey: .revision)
        replyTarget = try values.decodeIfPresent(TelegramComposerReplyTarget.self, forKey: .replyTarget)
        forwardIntent = try values.decodeIfPresent(TelegramComposerForwardIntent.self, forKey: .forwardIntent)
        forwardDisposition = try values.decodeIfPresent(TelegramComposerForwardDisposition.self, forKey: .forwardDisposition)
        if schemaVersion == 1 || schemaVersion == 2 {
            input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: values.decode(String.self, forKey: .text)))
        } else {
            input = try values.decode(TelegramComposerInput.self, forKey: .input)
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(accountID, forKey: .accountID); try values.encode(chatID, forKey: .chatID)
        try values.encodeIfPresent(threadID, forKey: .threadID)
        try values.encode(revision, forKey: .revision); try values.encodeIfPresent(replyTarget, forKey: .replyTarget)
        try values.encodeIfPresent(forwardIntent, forKey: .forwardIntent)
        try values.encodeIfPresent(forwardDisposition, forKey: .forwardDisposition)
        if schemaVersion == 1 || schemaVersion == 2 { try values.encode(text, forKey: .text) }
        else { try values.encode(input, forKey: .input) }
    }
}
