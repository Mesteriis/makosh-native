import Foundation
import MakoshCore

/// One locally stored message offered as AI context. `isProtected` marks
/// content Telegram forbids copying; the bridge drops it with a count.
public struct TelegramAIContextMessage: Sendable, Equatable {
    public let authorID: Int64
    public let authorName: String
    public let isOutgoing: Bool
    public let date: Date
    public let text: String
    public let isProtected: Bool
    public init(authorID: Int64, authorName: String, isOutgoing: Bool, date: Date, text: String, isProtected: Bool) {
        self.authorID = authorID
        self.authorName = authorName
        self.isOutgoing = isOutgoing
        self.date = date
        self.text = text
        self.isProtected = isProtected
    }
}

/// What the local history holds for one chat. A secret chat is never read.
public struct TelegramAIContextPage: Sendable, Equatable {
    public let isSecret: Bool
    /// A one-to-one chat with a user; `peerID` is that user.
    public let isPrivate: Bool
    public let peerID: Int64
    public let messages: [TelegramAIContextMessage]
    /// Messages read locally before the period was applied.
    public let available: Int
    /// The read stopped at its cap before reaching the start of the period.
    public let truncated: Bool
    public init(
        isSecret: Bool, isPrivate: Bool, peerID: Int64, messages: [TelegramAIContextMessage], available: Int, truncated: Bool = false
    ) {
        self.isSecret = isSecret
        self.isPrivate = isPrivate
        self.peerID = peerID
        self.messages = messages
        self.available = available
        self.truncated = truncated
    }
}

public enum TelegramAIContextProjection {
    /// The messages of a period, oldest first. Media without a caption keeps a placeholder.
    public static func select(_ all: [TelegramAIContextMessage], range: AIContextRange, now: Date) -> [TelegramAIContextMessage] {
        let ordered = all.sorted { $0.date < $1.date }
        let chosen: [TelegramAIContextMessage]
        switch range {
        case .latest(let count): chosen = Array(ordered.suffix(max(0, count)))
        case .lastDays(let days):
            let start = now.addingTimeInterval(-TimeInterval(days) * 86_400)
            chosen = ordered.filter { $0.date >= start }
        case .between(let from, let to): chosen = ordered.filter { $0.date >= from && $0.date <= to }
        }
        return chosen.map { message in
            guard message.text.isEmpty else { return message }
            return TelegramAIContextMessage(
                authorID: message.authorID, authorName: message.authorName, isOutgoing: message.isOutgoing, date: message.date,
                text: "[вложение]", isProtected: message.isProtected)
        }
    }
}
