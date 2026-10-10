import Foundation

/// Account-context scoped edit input. Deliberately not persisted across restart.
public struct TelegramMessageEditSession: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let revision: UUID
    public let source: TelegramMessageActionSource
    public let author: String
    public let contextID: UUID
    public let input: TelegramComposerInput

    init(id: UUID = UUID(), revision: UUID = UUID(), source: TelegramMessageActionSource,
         author: String, contextID: UUID, input: TelegramComposerInput) {
        self.id = id; self.revision = revision; self.source = source
        self.author = author; self.contextID = contextID; self.input = input
    }
}
