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

/// One message or letter of an attached source, ready for the provider.
public struct AIContextLine: Sendable, Equatable {
    public let author: String
    public let isOutgoing: Bool
    public let date: Date
    public let text: String
    public init(author: String, isOutgoing: Bool, date: Date, text: String) {
        self.author = author
        self.isOutgoing = isOutgoing
        self.date = date
        self.text = text
    }
}

/// What an attached card contributes, after access rules removed what may
/// not leave; the counts are shown on the card.
public struct AIContextMaterial: Sendable, Equatable {
    public let card: AIContextCard
    public let lines: [AIContextLine]
    public let hiddenForbidden: Int
    public let hiddenProtected: Int
    /// Messages available locally for the card's period.
    public let available: Int
    /// The `latest(n)` count asked for, if any.
    public let requested: Int?
    /// The local read stopped at its cap before covering the period.
    public let truncated: Bool
    public init(
        card: AIContextCard, lines: [AIContextLine], hiddenForbidden: Int, hiddenProtected: Int, available: Int, requested: Int?,
        truncated: Bool = false
    ) {
        self.card = card
        self.lines = lines
        self.hiddenForbidden = hiddenForbidden
        self.hiddenProtected = hiddenProtected
        self.available = available
        self.requested = requested
        self.truncated = truncated
    }
}

/// Reads an attached source. Throws `AIFailure.contextUnavailable` for a
/// source that may never be sent (secret chat, forbidden contact) or is gone.
public protocol AIContextProvider: Sendable {
    func material(for card: AIContextCard) async throws -> AIContextMaterial
}

/// The system turn carrying attached sources.
public enum AIContextBuilder {
    /// Nil without cards. Over the budget it throws instead of cutting anything.
    public static func turn(_ materials: [AIContextMaterial], history: [AIChatTurn], budgetTokens: Int) throws -> AIChatTurn? {
        guard !materials.isEmpty else { return nil }
        var text = """
            Ниже — переписка и письма, которые пользователь сам прикрепил к беседе. \
            Отвечай по ним; если ответа в них нет, так и скажи. \
            Реплики пользователя помечены «пользователь».
            """
        for material in materials {
            text += "\n\n=== \(heading(material.card)) ==="
            for line in material.lines {
                let date = line.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                let author = line.isOutgoing ? "пользователь" : line.author
                text += "\n[\(date)] \(author): \(line.text)"
            }
        }
        let total = history.reduce(0) { $0 + AITokenEstimate.tokens(in: $1.text) } + AITokenEstimate.tokens(in: text)
        guard total <= budgetTokens else { throw AIFailure.contextTooLarge(tokens: total, budget: budgetTokens) }
        return AIChatTurn(author: .system, text: text)
    }

    private static func heading(_ card: AIContextCard) -> String {
        switch card {
        case .chat(let service, _, _, let title, let range): "Чат «\(title)» (\(service), \(describe(range)))"
        case .letter(_, let title): "Письмо «\(title)»"
        case .contact(_, let title): "Контакт «\(title)»"
        }
    }

    private static func describe(_ range: AIContextRange) -> String {
        switch range {
        case .latest(let count): "последние \(count) сообщений"
        case .lastDays(let days): "за \(days) дн."
        case .between(let from, let to):
            "с \(from.formatted(.iso8601.year().month().day())) по \(to.formatted(.iso8601.year().month().day()))"
        }
    }
}

/// The "@word" typed at the end of a draft.
public enum AIMention {
    /// Nil unless the draft ends in "@" plus a word with no spaces, and the
    /// "@" starts a word (so an e-mail address is not a mention).
    public static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let word = draft[draft.index(after: at)...]
        return word.contains(where: \.isWhitespace) ? nil : String(word)
    }
    public static func removing(from draft: String) -> String {
        guard let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at])
    }
}
