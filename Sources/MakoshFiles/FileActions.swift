import Foundation

/// What a person can do with a file wherever it is shown.
public enum FileAction: Equatable, Sendable, CaseIterable {
    case sendToPaperless, forwardToChat, forwardByMail, askAI

    public var title: String {
        switch self {
        case .sendToPaperless: "Отправить в Paperless…"
        case .forwardToChat: "Отправить в чат…"
        case .forwardByMail: "Отправить письмом…"
        case .askAI: "Спросить ИИ…"
        }
    }
}

public enum FileActions {
    /// Protected content (Telegram copy protection, secret media, WhatsApp
    /// view-once) offers nothing; Paperless needs a connection.
    public static func available(protected: Bool, hasPaperless: Bool) -> [FileAction] {
        guard !protected else { return [] }
        return FileAction.allCases.filter { $0 != .sendToPaperless || hasPaperless }
    }
}
