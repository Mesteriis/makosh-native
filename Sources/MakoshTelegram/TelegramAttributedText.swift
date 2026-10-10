import AppKit

public enum TelegramAttributedTextError: Error, LocalizedError {
    case invalid
    public var errorDescription: String? { "Не удалось сохранить форматирование Telegram без потери данных." }
}
private final class TelegramEntityAttribute: NSObject, NSCopying {
    let kind: TelegramTextEntityKind
    let order: Int
    init(_ kind: TelegramTextEntityKind, order: Int) { self.kind = kind; self.order = order }
    func copy(with zone: NSZone? = nil) -> Any { self }
}

@MainActor public enum TelegramAttributedText {
    private static let prefix = "Makosh.TelegramEntity."
    public static func attributedString(_ value: TelegramFormattedText) throws -> NSAttributedString {
        let result = NSMutableAttributedString(string: value.text,attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
        for (index, entity) in value.entities.enumerated() {
            let range = NSRange(location: entity.offset,length: entity.length)
            result.addAttribute(NSAttributedString.Key(prefix + String(index)),value: TelegramEntityAttribute(entity.kind,order: index),range: range)
            switch entity.kind {
            case .bold, .italic, .code, .pre:
                result.enumerateAttribute(.font,in: range) { value, run, _ in
                    var font = value as? NSFont ?? NSFont.systemFont(ofSize: 14)
                    switch entity.kind {
                    case .bold: font = NSFontManager.shared.convert(font,toHaveTrait: .boldFontMask)
                    case .italic: font = NSFontManager.shared.convert(font,toHaveTrait: .italicFontMask)
                    default:
                        let traits = NSFontManager.shared.traits(of: font)
                        font = NSFont.monospacedSystemFont(ofSize: 14,weight: traits.contains(.boldFontMask) ? .bold : .regular)
                        if traits.contains(.italicFontMask) { font = NSFontManager.shared.convert(font,toHaveTrait: .italicFontMask) }
                    }
                    result.addAttribute(.font,value: font,range: run)
                }
            case .underline: result.addAttribute(.underlineStyle,value: NSUnderlineStyle.single.rawValue,range: range)
            case .strikethrough: result.addAttribute(.strikethroughStyle,value: NSUnderlineStyle.single.rawValue,range: range)
            case let .textURL(url): result.addAttribute(.link,value: url,range: range)
            case .spoiler: result.addAttribute(.backgroundColor,value: NSColor.secondaryLabelColor.withAlphaComponent(0.2),range: range)
            case .blockQuote: result.addAttribute(.foregroundColor,value: NSColor.secondaryLabelColor,range: range)
            default: break
            }
        }
        return result
    }
    public static func formattedText(_ value: NSAttributedString) throws -> TelegramFormattedText {
        var found: [String: (TelegramEntityAttribute, NSRange)] = [:]
        var invalid = false
        value.enumerateAttributes(in: NSRange(location: 0,length: value.length)) { attributes,range,_ in
            for (key, raw) in attributes where key.rawValue.hasPrefix(prefix) {
                guard let marker = raw as? TelegramEntityAttribute else { invalid = true; continue }
                if case let .textURL(expected) = marker.kind {
                    let rawLink = attributes[.link]
                    let actual = (rawLink as? String) ?? (rawLink as? URL)?.absoluteString
                    if actual?.utf8.elementsEqual(expected.utf8) != true { invalid = true }
                }
                if let old = found[key.rawValue] {
                    guard old.0 === marker, NSMaxRange(old.1) == range.location else { invalid = true; continue }
                    found[key.rawValue] = (marker,NSUnionRange(old.1,range))
                } else { found[key.rawValue] = (marker,range) }
            }
            // Embedded attachments cannot be represented as message text entities.
            if attributes[.attachment] != nil { invalid = true }
        }
        guard !invalid else { throw TelegramAttributedTextError.invalid }
        var entities = found.values.sorted { $0.0.order < $1.0.order }.map {
            TelegramTextEntity(offset: $0.1.location,length: $0.1.length,kind: $0.0.kind)
        }
        // Native font/menu formatting is admitted as entities rather than flattened.
        for kind in [TelegramTextEntityKind.bold,.italic,.underline,.strikethrough,.code] {
            var ranges: [NSRange] = []
            value.enumerateAttributes(in: NSRange(location: 0,length: value.length)) { attrs, range,_ in
                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let enabled: Bool
                switch kind {
                case .bold: enabled = traits.contains(.boldFontMask)
                case .italic: enabled = traits.contains(.italicFontMask)
                case .code: enabled = traits.contains(.fixedPitchFontMask)
                case .underline: enabled = (attrs[.underlineStyle] as? NSNumber)?.intValue != nil && (attrs[.underlineStyle] as? NSNumber)?.intValue != 0
                default: enabled = (attrs[.strikethroughStyle] as? NSNumber)?.intValue != nil && (attrs[.strikethroughStyle] as? NSNumber)?.intValue != 0
                }
                if enabled {
                    if let last = ranges.last,NSMaxRange(last) == range.location { ranges[ranges.count - 1] = NSUnionRange(last,range) }
                    else { ranges.append(range) }
                }
            }
            let originals = entities.filter { entity in
                if entity.kind == kind { return true }
                if kind == .code, case .pre = entity.kind { return true }
                return false
            }
            for entity in originals {
                guard ranges.contains(where: { NSLocationInRange(entity.offset,$0) && NSMaxRange($0) >= entity.offset + entity.length }) else { throw TelegramAttributedTextError.invalid }
            }
            for range in ranges where !originals.contains(where: { $0.offset <= range.location && $0.offset + $0.length >= NSMaxRange(range) }) {
                guard !originals.contains(where: { NSIntersectionRange(NSRange(location: $0.offset,length: $0.length),range).length > 0 }) else { throw TelegramAttributedTextError.invalid }
                entities.append(TelegramTextEntity(offset: range.location,length: range.length,kind: kind))
            }
        }
        value.enumerateAttribute(.link,in: NSRange(location: 0,length: value.length)) { raw,range,_ in
            guard let raw else { return }
            let url = (raw as? String) ?? (raw as? URL)?.absoluteString
            guard let url else { invalid = true; return }
            let matching = entities.contains { $0.offset == range.location && $0.length == range.length && $0.kind == .textURL(url: url) }
            if !matching { entities.append(TelegramTextEntity(offset: range.location,length: range.length,kind: .textURL(url: url))) }
        }
        guard !invalid else { throw TelegramAttributedTextError.invalid }
        return try TelegramFormattedText(text: value.string,entities: entities)
    }
}
