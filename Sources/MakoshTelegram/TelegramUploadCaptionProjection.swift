import Foundation

/// Own send projection for explicitly versioned preparations. The editor and
/// all earlier schema families retain their original text and entity recipe.
enum TelegramUploadCaptionProjection {
    private struct Token {
        let range: Range<Int>
        let body: Range<Int>
        let kind: TelegramTextEntityKind
        let protectedRange: Range<Int>
    }

    static func project(_ value: TelegramFormattedText, allowCustomEmoji: Bool = false) throws -> TelegramFormattedText {
        let source = try TelegramUploadCaptionRules.referenceProjection(value, allowCustomEmoji: allowCustomEmoji)
        let units = Array(source.text.utf16)
        var tokens: [Token] = [], cursor = 0
        while cursor < units.count {
            if let token = token(in: units, at: cursor), !source.entities.contains(where: {
                $0.offset < token.protectedRange.upperBound && $0.offset + $0.length > token.protectedRange.lowerBound
            }) {
                tokens.append(token); cursor = token.range.upperBound
            } else { cursor += 1 }
        }
        var output: [UInt16] = [], generated: [TelegramTextEntity] = [], end = 0
        for token in tokens {
            output.append(contentsOf: units[end..<token.range.lowerBound])
            let offset = output.count
            output.append(contentsOf: units[token.body])
            generated.append(.init(offset: offset, length: token.body.count, kind: token.kind))
            end = token.range.upperBound
        }
        output.append(contentsOf: units[end...])
        let explicit = source.entities.map { entity in
            let removed = tokens.filter { $0.range.upperBound <= entity.offset }
                .reduce(0) { $0 + $1.range.count - $1.body.count }
            return TelegramTextEntity(offset: entity.offset - removed, length: entity.length, kind: entity.kind)
        }
        let formatted = try TelegramFormattedText(text: String(decoding: output, as: UTF16.self), entities: explicit + generated)
        let trimmed = try TelegramUploadCaptionRules.referenceProjection(formatted, allowCustomEmoji: allowCustomEmoji)
        let detected = try hashtags(in: trimmed)
        let ordered = (trimmed.entities + detected).enumerated().sorted {
            $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset
        }.map(\.element)
        return try TelegramFormattedText(text: trimmed.text, entities: ordered)
    }

    private static func token(in units: [UInt16], at start: Int) -> Token? {
        guard start == 0 || whitespace(units[start - 1]) else { return nil }
        let delimiters: [([UInt16], TelegramTextEntityKind)] = [
            ([42, 42], .bold), ([95, 95], .italic), ([126, 126], .strikethrough),
            ([124, 124], .spoiler), ([96], .code)]
        let fenced = matches([96, 96, 96], in: units, at: start)
        let opening: [UInt16], kind: TelegramTextEntityKind
        if fenced {
            opening = matches([96, 96, 96, 96], in: units, at: start) ? [96, 96, 96, 96] : [96, 96, 96]
            kind = .pre(language: "")
        } else {
            guard let delimiter = delimiters.first(where: { matches($0.0, in: units, at: start) }) else { return nil }
            opening = delimiter.0; kind = delimiter.1
        }
        let bodyStart = start + opening.count
        var close = bodyStart + 1
        while close < units.count {
            if !fenced, units[close - 1] == 10 { return nil }
            let closing = fenced && matches([96, 96, 96, 96], in: units, at: close)
                ? [UInt16](repeating: 96, count: 4) : fenced ? [UInt16](repeating: 96, count: 3) : opening
            if matches(closing, in: units, at: close), boundary(units, at: close + closing.count) {
                var body = bodyStart..<close, resultKind = kind
                if fenced {
                    var language = ""
                    if let newline = units[body].firstIndex(of: 10), newline > bodyStart {
                        let candidate = String(decoding: units[bodyStart..<newline], as: UTF16.self)
                        if candidate.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count == candidate.utf16.count {
                            language = candidate; body = newline..<close
                        }
                    }
                    resultKind = .pre(language: language)
                }
                let end = close + closing.count
                return .init(range: start..<end, body: body, kind: resultKind,
                    protectedRange: max(0, start - 1)..<min(units.count, end + 1))
            }
            close += 1
        }
        return nil
    }

    private static func matches(_ delimiter: [UInt16], in units: [UInt16], at offset: Int) -> Bool {
        offset <= units.count - delimiter.count && units[offset..<(offset + delimiter.count)].elementsEqual(delimiter)
    }
    private static func whitespace(_ unit: UInt16) -> Bool {
        UnicodeScalar(UInt32(unit)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }
    private static func boundary(_ units: [UInt16], at offset: Int) -> Bool {
        offset == units.count || whitespace(units[offset]) || [46, 44, 58, 63, 33, 59].contains(units[offset])
    }

    private static func hashtags(in value: TelegramFormattedText) throws -> [TelegramTextEntity] {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let links = detector.matches(in: value.text, range: NSRange(location: 0, length: value.text.utf16.count)).map(\.range)
        let units = Array(value.text.utf16)
        var result: [TelegramTextEntity] = [], cursor = 0
        while cursor < units.count {
            guard units[cursor] == 35 else { cursor += 1; continue }
            var end = cursor + 1
            while end < units.count, units[end] == 95 ||
                (UnicodeScalar(UInt32(units[end])).map { CharacterSet.alphanumerics.contains($0) } ?? false) { end += 1 }
            // The selected reference requires two body units for an EOF tag;
            // a one-unit body followed by punctuation remains detectable.
            if end > cursor + 1, end < units.count || end - cursor > 2 {
                let range = NSRange(location: cursor, length: end - cursor)
                let entity = TelegramTextEntity(offset: cursor, length: end - cursor, kind: .hashtag)
                if !links.contains(where: { NSIntersectionRange($0, range).length > 0 }), !value.entities.contains(entity) {
                    result.append(entity)
                }
            }
            cursor = max(cursor + 1, end)
        }
        return result
    }
}
