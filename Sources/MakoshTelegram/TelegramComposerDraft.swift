import Foundation

/// A versioned composer snapshot. Empty text is a retained deletion tombstone.
struct TelegramComposerDraft: Codable, Equatable, Sendable {
    static let maximumTextBytes = 64 * 1024
    let schemaVersion: Int
    let accountID: Int64
    let chatID: Int64
    let revision: UUID
    let text: String
    init(accountID: Int64, chatID: Int64, text: String, revision: UUID = UUID()) {
        schemaVersion = 1; self.accountID = accountID; self.chatID = chatID
        self.revision = revision; self.text = text
    }
    var isValid: Bool { schemaVersion == 1 && text.utf8.count <= Self.maximumTextBytes }
    static func == (lhs: Self,rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.accountID == rhs.accountID && lhs.chatID == rhs.chatID &&
            lhs.revision == rhs.revision && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}
