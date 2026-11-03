import AppKit

/// Semantic colors only; the captured message continues to own text and styles.
public enum TelegramCodeHighlightRole: UInt32, Sendable {
    case plain = 0, comment, property, green, red, purple, blue
}

public struct TelegramCodeHighlightSpan: Equatable, Sendable {
    public let range: NSRange
    public let role: TelegramCodeHighlightRole
}

struct TelegramCodeHighlightByteSpan: Sendable {
    let offset: Int
    let length: Int
    let role: UInt32
}

public struct TelegramCodeHighlight: Sendable {
    private let sourceUTF8: [UInt8]
    public let spans: [TelegramCodeHighlightSpan]

    init?(source: String, byteSpans: [TelegramCodeHighlightByteSpan]) {
        guard source.utf16.prefix(32769).count <= 32768, byteSpans.count <= 8192 else { return nil }
        let bytes = Array(source.utf8)
        guard bytes.count <= 131072 else { return nil }
        var boundaries = [Int](repeating: -1, count: bytes.count + 1)
        var byteOffset = 0, unitOffset = 0
        boundaries[0] = 0
        for scalar in source.unicodeScalars {
            byteOffset += scalar.value <= 0x7F ? 1 : scalar.value <= 0x7FF ? 2 : scalar.value <= 0xFFFF ? 3 : 4
            unitOffset += scalar.value > 0xFFFF ? 2 : 1
            boundaries[byteOffset] = unitOffset
        }
        var validated: [TelegramCodeHighlightSpan] = []
        validated.reserveCapacity(byteSpans.count)
        var previousEnd = 0
        for span in byteSpans {
            guard span.offset >= previousEnd, span.offset <= bytes.count, span.length > 0,
                  span.length <= bytes.count - span.offset,
                  let role = TelegramCodeHighlightRole(rawValue: span.role) else { return nil }
            let end = span.offset + span.length
            let startUnit = boundaries[span.offset], endUnit = boundaries[end]
            guard startUnit >= 0, endUnit > startUnit else { return nil }
            validated.append(.init(range: NSRange(location: startUnit, length: endUnit - startUnit), role: role))
            previousEnd = end
        }
        sourceUTF8 = bytes; spans = validated
    }

    public func matches(_ source: String) -> Bool {
        sourceUTF8.elementsEqual(source.utf8)
    }
}

/// Colors are resolved when rendering, never captured by a background parse.
@MainActor public struct TelegramCodeHighlightPalette {
    public var text: NSColor
    public var comment: NSColor
    public var property: NSColor
    public var green: NSColor
    public var red: NSColor
    public var purple: NSColor
    public var blue: NSColor

    public init(text: NSColor = .labelColor, comment: NSColor = .secondaryLabelColor,
                property: NSColor = .systemPurple, green: NSColor = .systemGreen,
                red: NSColor = .systemRed, purple: NSColor = .systemPurple,
                blue: NSColor = .linkColor) {
        self.text = text; self.comment = comment; self.property = property
        self.green = green; self.red = red; self.purple = purple; self.blue = blue
    }

    fileprivate func color(_ role: TelegramCodeHighlightRole) -> NSColor {
        switch role {
        case .plain: text
        case .comment: comment
        case .property: property
        case .green: green
        case .red: red
        case .purple: purple
        case .blue: blue
        }
    }
}

@MainActor public enum TelegramCodeHighlightPresentation {
    public static func attributedString(_ value: TelegramFormattedText,
        highlight: TelegramCodeHighlight?, revealingSpoilers: Bool = false,
        palette: TelegramCodeHighlightPalette = .init()) -> NSAttributedString {
        let baseline = TelegramMessagePresentation.attributedString(value, revealingSpoilers: revealingSpoilers)
        guard let highlight, highlight.matches(value.text), baseline.length > 0 else { return baseline }
        let result = NSMutableAttributedString(attributedString: baseline)
        // Difference ranges make nested/overlapping spoilers linear in source length.
        // Safe links keep their own color and complete existing attributes.
        var differences = [Int](repeating: 0, count: baseline.length + 1)
        if !revealingSpoilers {
            for entity in value.entities {
                if case .spoiler = entity.kind {
                    differences[entity.offset] += 1
                    differences[entity.offset + entity.length] -= 1
                }
            }
        }
        baseline.enumerateAttribute(.link, in: NSRange(location: 0, length: baseline.length)) { link, range, _ in
            if link != nil {
                differences[range.location] += 1
                differences[NSMaxRange(range)] -= 1
            }
        }
        var protected = [Bool](repeating: false, count: baseline.length)
        var depth = 0
        for index in protected.indices {
            depth += differences[index]; protected[index] = depth > 0
        }
        for span in highlight.spans {
            var index = span.range.location
            let end = NSMaxRange(span.range)
            while index < end {
                if protected[index] { index += 1; continue }
                let start = index
                repeat { index += 1 } while index < end && !protected[index]
                result.addAttribute(.foregroundColor, value: palette.color(span.role),
                    range: NSRange(location: start, length: index - start))
            }
        }
        return NSAttributedString(attributedString: result)
    }
}
