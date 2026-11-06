import Foundation

/// Text read for a file card, kept for the session so previews and sends
/// never download or OCR the same pages twice. Bounded; a removed card's
/// entries are forgotten.
public actor FileMaterialCache {
    public struct Entry: Sendable {
        public let text: ExtractedText
        public let fallback: String?
        public init(text: ExtractedText, fallback: String?) {
            self.text = text
            self.fallback = fallback
        }
    }
    private let limit: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    public init(limit: Int = 32) { self.limit = max(limit, 1) }

    public func value(for key: String) -> Entry? { entries[key] }

    public func store(_ entry: Entry, for key: String) {
        if entries[key] == nil { order.append(key) }
        entries[key] = entry
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }

    /// Keys are "<cardID>|<pages>"; everything of the card goes.
    public func forget(cardID: String) {
        let prefix = cardID + "|"
        order.removeAll { $0.hasPrefix(prefix) }
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    public func clear() {
        entries = [:]
        order = []
    }
}
