import Foundation
import MakoshCore

/// A source the user attached to a conversation. Attaching it is consent to
/// send its content to the chat provider with each question; nothing else
/// leaves. A chat card carries its period; letters and contacts go whole.
public enum AIContextCard: Codable, Hashable, Sendable, Identifiable {
    case chat(service: String, accountID: String, chatID: String, title: String, range: AIContextRange)
    case letter(id: String, title: String)
    case contact(id: UUID, title: String)

    /// The source, independent of the chosen period.
    public var id: String {
        switch self {
        case .chat(let service, let accountID, let chatID, _, _): "chat:\(service):\(accountID):\(chatID)"
        case .letter(let id, _): "letter:\(id)"
        case .contact(let id, _): "contact:\(id.uuidString)"
        }
    }

    public var title: String {
        switch self {
        case .chat(_, _, _, let title, _), .letter(_, let title), .contact(_, let title): title
        }
    }
}
