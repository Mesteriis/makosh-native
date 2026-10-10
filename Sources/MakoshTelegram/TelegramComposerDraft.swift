import Foundation
import TelegramCore

struct TelegramComposerReplyTarget: Codable, Equatable, Sendable {
    let peerID: Int64
    let namespace: Int32
    let messageID: Int32
    let threadID: Int64?
    init(peerID: Int64, namespace: Int32, messageID: Int32, threadID: Int64? = nil) {
        self.peerID = peerID; self.namespace = namespace; self.messageID = messageID; self.threadID = threadID
    }
    init(source: TelegramMessageActionSource) {
        self.init(peerID: source.peerID, namespace: source.namespace, messageID: source.messageID, threadID: source.threadID)
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
    let input: TelegramComposerInput
    var text: String { input.formattedText.text }
    let replyTarget: TelegramComposerReplyTarget?
    init(accountID: Int64, chatID: Int64, text: String, revision: UUID = UUID(), replyTarget: TelegramComposerReplyTarget? = nil) {
        self.init(accountID: accountID, chatID: chatID, input: try! TelegramComposerInput(formattedText: TelegramFormattedText(text: text)), revision: revision, replyTarget: replyTarget)
    }
    init(accountID: Int64, chatID: Int64, input: TelegramComposerInput, revision: UUID = UUID(), replyTarget: TelegramComposerReplyTarget? = nil) {
        schemaVersion = 3; self.accountID = accountID; self.chatID = chatID
        self.revision = revision; self.input = input; self.replyTarget = replyTarget
    }
    var isValid: Bool {
        (schemaVersion == 1 && replyTarget == nil || (schemaVersion == 2 || schemaVersion == 3) && (replyTarget?.isValid ?? true)) && text.utf8.count <= Self.maximumTextBytes
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, accountID, chatID, revision, text, input, replyTarget }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        accountID = try values.decode(Int64.self, forKey: .accountID)
        chatID = try values.decode(Int64.self, forKey: .chatID)
        revision = try values.decode(UUID.self, forKey: .revision)
        replyTarget = try values.decodeIfPresent(TelegramComposerReplyTarget.self, forKey: .replyTarget)
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
        try values.encode(revision, forKey: .revision); try values.encodeIfPresent(replyTarget, forKey: .replyTarget)
        if schemaVersion == 1 || schemaVersion == 2 { try values.encode(text, forKey: .text) }
        else { try values.encode(input, forKey: .input) }
    }
}
