import Foundation

public enum TelegramMessageBlockKind: Equatable, Sendable {
    case text
    case code(language: String?)
    case quote(isCollapsed: Bool)
}

public struct TelegramMessageBlock: Equatable, Sendable {
    /// Half-open UTF16 offsets in the original, unmodified source.
    public let range: Range<Int>
    public let kind: TelegramMessageBlockKind
    public let value: TelegramFormattedText
}

/// Reading projection only. Ambiguous structural/semantic splits retain a
/// single original text block instead of guessing or changing link targets.
public func telegramMessageBlocks(_ value: TelegramFormattedText) -> [TelegramMessageBlock] {
    let count = value.text.utf16.count
    let fallback = [TelegramMessageBlock(range: 0..<count, kind: .text, value: value)]
    let structures = value.entities.filter {
        switch $0.kind { case .pre, .blockQuote: true; default: false }
    }.sorted { $0.offset < $1.offset }
    guard !structures.isEmpty else { return fallback }
    for (a, b) in zip(structures, structures.dropFirst()) {
        guard a.offset + a.length <= b.offset else { return fallback }
    }
    var segments: [(Range<Int>, TelegramMessageBlockKind)] = []
    var cursor = 0
    for entity in structures {
        if cursor < entity.offset { segments.append((cursor..<entity.offset, .text)) }
        let kind: TelegramMessageBlockKind
        switch entity.kind {
        case let .pre(language): kind = .code(language: language)
        case let .blockQuote(collapsed): kind = .quote(isCollapsed: collapsed)
        default: return fallback
        }
        cursor = entity.offset + entity.length
        segments.append((entity.offset..<cursor, kind))
    }
    if cursor < count { segments.append((cursor..<count, .text)) }
    let cuts = segments.dropLast().map { $0.0.upperBound }
    for entity in value.entities where cuts.contains(where: { entity.offset < $0 && $0 < entity.offset + entity.length }) {
        switch entity.kind {
        case .bold, .italic, .underline, .strikethrough, .spoiler, .code: break
        default: return fallback
        }
    }
    let units = Array(value.text.utf16)
    var result: [TelegramMessageBlock] = []
    for (range, kind) in segments {
        let entities = value.entities.compactMap { entity -> TelegramTextEntity? in
            let lower = max(range.lowerBound, entity.offset)
            let upper = min(range.upperBound, entity.offset + entity.length)
            guard lower < upper else { return nil }
            if case .quote = kind, case .blockQuote = entity.kind { return nil }
            return TelegramTextEntity(offset: lower - range.lowerBound, length: upper - lower, kind: entity.kind)
        }
        let text = String(decoding: units[range], as: UTF16.self)
        guard let sliced = try? TelegramFormattedText(text: text, entities: entities) else { return fallback }
        result.append(TelegramMessageBlock(range: range, kind: kind, value: sliced))
    }
    return result
}
