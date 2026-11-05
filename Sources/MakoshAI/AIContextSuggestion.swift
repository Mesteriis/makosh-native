import Foundation

/// A source offered by "+" and "@".
public struct AIContextSuggestion: Sendable, Equatable, Identifiable {
    public let card: AIContextCard
    public let subtitle: String
    public var id: String { card.id }
    public init(card: AIContextCard, subtitle: String) {
        self.card = card
        self.subtitle = subtitle
    }
}

public enum AIContextRanking {
    /// Title starts with the query, then a word starts with it, then it appears
    /// anywhere. Case and ё/е are ignored; equal matches keep their order.
    public static func rank(_ items: [AIContextSuggestion], query: String, limit: Int) -> [AIContextSuggestion] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return Array(items.prefix(limit)) }
        let scored = items.enumerated().compactMap { index, item -> (Int, Int, AIContextSuggestion)? in
            let title = fold(item.card.title)
            if title.hasPrefix(needle) { return (0, index, item) }
            if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) {
                return (1, index, item)
            }
            if title.contains(needle) || fold(item.subtitle).contains(needle) { return (2, index, item) }
            return nil
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(limit).map(\.2)
    }

    private static func fold(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "ё", with: "е") }
}
