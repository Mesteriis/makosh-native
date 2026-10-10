import AppKit

/// A reveal applies only to this context and exact captured message version.
public struct TelegramMessagePresentationKey: Equatable, Sendable {
    public let context: String
    public let value: TelegramFormattedText
    public init(context: String, value: TelegramFormattedText) {
        self.context = context; self.value = value
    }
}

/// Reading-only presentation. No editor markers, fetches or URL activation.
@MainActor public enum TelegramMessagePresentation {
    public static func plainText(_ value: TelegramFormattedText, revealingSpoilers: Bool = false) -> String {
        let hidden = revealingSpoilers ? [] : mergedSpoilers(value.entities)
        var units = Array(value.text.utf16)
        for range in hidden {
            for index in range.location..<NSMaxRange(range) { units[index] = 0x2588 }
        }
        return String(decoding: units, as: UTF16.self)
    }
    public static func attributedString(_ value: TelegramFormattedText, revealingSpoilers: Bool = false) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 14)
        let hidden = revealingSpoilers ? [] : mergedSpoilers(value.entities)
        let result = NSMutableAttributedString(string: plainText(value, revealingSpoilers: revealingSpoilers),
            attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        for entity in value.entities {
            let range = NSRange(location: entity.offset, length: entity.length)
            switch entity.kind {
            case .bold, .italic, .code, .pre:
                result.enumerateAttribute(.font, in: range) { raw, run, _ in
                    var current = raw as? NSFont ?? font
                    switch entity.kind {
                    case .bold: current = NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask)
                    case .italic: current = NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask)
                    default:
                        let traits = NSFontManager.shared.traits(of: current)
                        current = NSFont.monospacedSystemFont(ofSize: 14, weight: traits.contains(.boldFontMask) ? .bold : .regular)
                        if traits.contains(.italicFontMask) { current = NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask) }
                    }
                    result.addAttribute(.font, value: current, range: run)
                }
            case .underline: result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .strikethrough: result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .blockQuote:
                let paragraph = NSMutableParagraphStyle()
                paragraph.headIndent = 12; paragraph.firstLineHeadIndent = 12; paragraph.paragraphSpacing = 4
                result.addAttributes([.paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor], range: range)
            case .url, .email, .textURL:
                // A partially hidden link must not retain the complete secret target
                // in a visible run's attributes, copy representation or accessibility.
                guard !hidden.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                let target: String
                switch entity.kind {
                case let .textURL(url): target = url
                case .email: target = "mailto:" + (value.text as NSString).substring(with: range)
                default: target = (value.text as NSString).substring(with: range)
                }
                if let url = safeURL(target) {
                    result.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: range)
                }
            default: break
            }
        }
        for range in hidden {
            // No source strings, URLs, language hints, emoji IDs or editor metadata.
            result.setAttributes([.font: font, .foregroundColor: NSColor.secondaryLabelColor], range: range)
        }
        return NSAttributedString(attributedString: result)
    }

    private static func mergedSpoilers(_ entities: [TelegramTextEntity]) -> [NSRange] {
        let ranges = entities.compactMap { entity -> NSRange? in
            guard case .spoiler = entity.kind else { return nil }
            return NSRange(location: entity.offset, length: entity.length)
        }.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in ranges {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else { result.append(range) }
        }
        return result
    }

    private static func safeURL(_ raw: String) -> URL? {
        func forbidden(_ text: String) -> Bool {
            text.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) ||
                    $0.properties.generalCategory == .format
            }
        }
        guard !raw.isEmpty, !forbidden(raw), let decoded = raw.removingPercentEncoding, !forbidden(decoded) else { return nil }
        let normalized: String
        if URLComponents(string: raw)?.scheme == nil {
            guard !raw.hasPrefix("/"), !raw.hasPrefix("."),
                  let host = URLComponents(string: "https://" + raw)?.host, host.contains(".") else { return nil }
            normalized = "https://" + raw
        } else { normalized = raw }
        guard let components = URLComponents(string: normalized), let scheme = components.scheme?.lowercased(),
              components.user == nil, components.password == nil else { return nil }
        switch scheme {
        case "https", "http":
            guard let host = components.host, !host.isEmpty,
                  components.port == nil || (1...65535).contains(components.port!) else { return nil }
        case "mailto":
            guard components.host == nil, components.query == nil, components.fragment == nil,
                  components.path.contains("@"), !components.path.hasPrefix("//") else { return nil }
        default: return nil
        }
        return components.url
    }
}
