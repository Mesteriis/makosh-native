import Foundation
import TelegramCore
import Postbox

public struct TelegramReplyQuote: Codable, Equatable, Sendable {
    // Server drafts can carry a quote without its original selection offset.
    public let selection: TelegramInputSelection?
    public let formattedText: TelegramFormattedText
    private let mediaData: Data?
    public init?(source: TelegramFormattedText, selection: TelegramInputSelection, maximumLength: Int = 1024) {
        let count = source.text.utf16.count
        guard maximumLength > 0, selection.location >= 0, selection.length > 0, selection.length <= maximumLength,
              selection.location <= count, selection.length <= count - selection.location else { return nil }
        var boundaries: Set<Int> = [0], cursor = 0
        for scalar in source.text.unicodeScalars {
            cursor += scalar.value > 0xffff ? 2 : 1; boundaries.insert(cursor)
        }
        guard boundaries.contains(selection.location), boundaries.contains(selection.location + selection.length) else { return nil }
        let requested = selection.location..<(selection.location + selection.length)
        // A custom emoji is one semantic run, even when its fallback contains
        // several scalars. Never turn part of that fallback into a new entity.
        for entity in source.entities {
            guard case .customEmoji = entity.kind else { continue }
            let run = entity.offset..<(entity.offset + entity.length)
            if run.overlaps(requested) && !(requested.lowerBound <= run.lowerBound && requested.upperBound >= run.upperBound) { return nil }
        }
        let normalized = (source.text as NSString).substring(with: NSRange(location: selection.location, length: selection.length))
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{fffc}", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Find the prefix independently of the trailing whitespace.
        var prefix = 0
        for scalar in normalized.unicodeScalars {
            guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            prefix += scalar.value > 0xffff ? 2 : 1
        }
        let range = (selection.location + prefix)..<(selection.location + prefix + trimmed.utf16.count)
        let entities = source.entities.compactMap { entity -> TelegramTextEntity? in
            guard Self.isQuoteable(entity.kind) else { return nil }
            let lower = max(entity.offset, range.lowerBound), upper = min(entity.offset + entity.length, range.upperBound)
            guard lower < upper else { return nil }
            return .init(offset: lower - range.lowerBound, length: upper - lower, kind: entity.kind)
        }
        guard let value = try? TelegramFormattedText(text: trimmed, entities: entities) else { return nil }
        self.selection = .init(location: range.lowerBound, length: range.count)
        self.formattedText = value
        self.mediaData = nil
    }
    public func matches(source: TelegramFormattedText, maximumLength: Int = 1024) -> Bool {
        if let selection {
            return Self(source: source, selection: selection, maximumLength: maximumLength)?.formattedText == formattedText
        }
        let text = source.text as NSString
        var start = 0
        while start < text.length {
            let found = text.range(of: formattedText.text, options: .literal, range: NSRange(location: start, length: text.length - start))
            guard found.location != NSNotFound else { return false }
            if Self(source: source, selection: .init(location: found.location, length: found.length), maximumLength: maximumLength)?.formattedText == formattedText { return true }
            start = found.location + max(1, found.length)
        }
        return false
    }
    init(native: EngineMessageReplyQuote) throws {
        let text = try telegramFormattedText(text: native.text, entities: native.entities)
        guard Self.valid(text), native.offset.map({ $0 >= 0 && $0 <= Int(Int32.max) - text.text.utf16.count }) ?? true else { throw TelegramFormattedTextError.invalid }
        formattedText = text
        selection = native.offset.map { .init(location: $0, length: text.text.utf16.count) }
        if let media = native.media {
            let encoder = PostboxEncoder(); encoder.encodeRootObject(media)
            let data = encoder.makeData()
            guard data.count <= 128 * 1024 else { throw TelegramFormattedTextError.invalid }
            mediaData = data
        } else { mediaData = nil }
    }
    func nativeDraftQuote() -> EngineMessageReplyQuote {
        EngineMessageReplyQuote(text: formattedText.text, offset: selection?.location, entities: formattedText.engineEntities(),
            media: mediaData.flatMap { PostboxDecoder(buffer: MemoryBuffer(data: $0)).decodeRootObject() as? Media })
    }
    private static func isQuoteable(_ kind: TelegramTextEntityKind) -> Bool {
        switch kind { case .bold, .italic, .underline, .strikethrough, .spoiler, .customEmoji: true; default: false }
    }
    private static func valid(_ value: TelegramFormattedText) -> Bool {
        !value.text.isEmpty && value.text.utf8.count <= TelegramComposerDraft.maximumTextBytes &&
        value.entities.allSatisfy({ Self.isQuoteable($0.kind) }) &&
        value.text.utf8.elementsEqual(value.text.trimmingCharacters(in: .whitespacesAndNewlines).utf8) &&
        !value.text.contains("\u{2028}") && !value.text.contains("\u{fffc}")
    }
    private enum CodingKeys: String, CodingKey { case selection, formattedText, mediaData }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selection = try values.decodeIfPresent(TelegramInputSelection.self, forKey: .selection)
        formattedText = try values.decode(TelegramFormattedText.self, forKey: .formattedText)
        mediaData = try values.decodeIfPresent(Data.self, forKey: .mediaData)
        let validSelection = selection.map { $0.location >= 0 && $0.length > 0 &&
            $0.location <= Int(Int32.max) - $0.length && $0.length == formattedText.text.utf16.count } ?? true
        guard validSelection, Self.valid(formattedText), mediaData.map({ !$0.isEmpty && $0.count <= 128 * 1024 }) ?? true else {
            throw TelegramFormattedTextError.invalid
        }
    }
}

nonisolated func telegramReplyQuoteLimit(transaction: Transaction) -> Int {
    guard case let .dictionary(values)? = currentAppConfiguration(transaction: transaction).data,
          case let .number(value)? = values["quote_length_max"], value.isFinite,
          value >= 1, value <= Double(Int32.max), value.rounded(.towardZero) == value else { return 1024 }
    return Int(value)
}
