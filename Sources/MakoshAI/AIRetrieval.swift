import Foundation
import MakoshCore

public struct AISourceReference: Codable, Equatable, Sendable {
    public let identity: MessageArchiveIdentity
    public let title: String
    public let date: Date
    public init(identity: MessageArchiveIdentity, title: String, date: Date) {
        self.identity = identity
        self.title = title
        self.date = date
    }
}

/// Retrieval limits and the context turn that carries permitted chunks.
public enum AIRetrieval {
    public static let limit = 8
    public static let maxDistance = 0.6

    static func context(_ chunks: [AIChunk]) -> (turn: AIChatTurn, sources: [AISourceReference]) {
        var text = """
            Ниже — фрагменты из переписки и писем пользователя в Макоше, к которым он открыл доступ. \
            Если они относятся к вопросу, отвечай по ним и указывай номера фрагментов в квадратных скобках, например [1]. \
            Если ответа во фрагментах нет, так и скажи.
            """
        var sources: [AISourceReference] = []
        for (index, chunk) in chunks.enumerated() {
            let date = chunk.date.formatted(.iso8601.year().month().day())
            text += "\n\n[\(index + 1)] \(chunk.title.isEmpty ? "Переписка" : chunk.title), \(date)\n\(chunk.text)"
            if let identity = chunk.messages.last {
                sources.append(AISourceReference(identity: identity, title: chunk.title, date: chunk.date))
            }
        }
        return (AIChatTurn(author: .system, text: text), sources)
    }
}
