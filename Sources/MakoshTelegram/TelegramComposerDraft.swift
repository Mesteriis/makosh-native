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
    let text: String
    let replyTarget: TelegramComposerReplyTarget?
    init(accountID: Int64, chatID: Int64, text: String, revision: UUID = UUID(), replyTarget: TelegramComposerReplyTarget? = nil) {
        schemaVersion = 2; self.accountID = accountID; self.chatID = chatID
        self.revision = revision; self.text = text; self.replyTarget = replyTarget
    }
    var isValid: Bool { (schemaVersion == 1 && replyTarget == nil || schemaVersion == 2 && (replyTarget?.isValid ?? true)) && text.utf8.count <= Self.maximumTextBytes }
    static func == (lhs: Self,rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.accountID == rhs.accountID && lhs.chatID == rhs.chatID &&
            lhs.revision == rhs.revision && lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.replyTarget == rhs.replyTarget
    }
}
