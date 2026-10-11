import Foundation

/// Schema15 changes the send projection, never the durable editor input.
/// Earlier preparations retain their original caption and receipt semantics.
enum TelegramUploadCaptionRules: Sendable {
    case legacy, reference

    func projection(_ value: TelegramFormattedText) throws -> TelegramFormattedText {
        guard self == .reference else { return value }
        guard value.isEditable, !value.entities.contains(where: {
            if case .customEmoji = $0.kind { return true }; return false
        }) else { throw TelegramFormattedTextError.invalid }
        // Both reference substitutions retain one UTF16 unit; only edge trimming
        // changes entity offsets. Keep the platform reference whitespace set.
        let replaced = value.text.replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{fffc}", with: "\n")
        let scalars = replaced.unicodeScalars
        var start = scalars.startIndex, end = scalars.endIndex, prefix = 0, suffix = 0
        while start < end, CharacterSet.whitespacesAndNewlines.contains(scalars[start]) {
            prefix += scalars[start].value > 0xffff ? 2 : 1
            start = scalars.index(after: start)
        }
        while end > start {
            let previous = scalars.index(before: end)
            guard CharacterSet.whitespacesAndNewlines.contains(scalars[previous]) else { break }
            suffix += scalars[previous].value > 0xffff ? 2 : 1
            end = previous
        }
        let upper = replaced.utf16.count - suffix
        let entities = value.entities.compactMap { entity -> TelegramTextEntity? in
            let lower = max(prefix, entity.offset), end = min(upper, entity.offset + entity.length)
            guard lower < end else { return nil }
            return .init(offset: lower - prefix, length: end - lower, kind: entity.kind)
        }
        return try TelegramFormattedText(text: String(scalars[start..<end]), entities: entities)
    }

    func validationUTF16Count(_ value: TelegramFormattedText) -> Int {
        guard self == .reference else { return value.text.utf16.count }
        return value.text.replacingOccurrences(of: "\u{2028}", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
    }

    func canSend(_ value: TelegramFormattedText) -> Bool {
        guard validationUTF16Count(value) <= 1024, let projected = try? projection(value) else { return false }
        return telegramFormattedCaptionCanSend(projected)
    }

    static func canHaveCaption(kind: String?, metadata: TelegramUploadMetadata?, selectionMIME: String?) -> Bool {
        guard kind == TelegramUploadMode.file.rawValue else { return true }
        if case .webP? = metadata { return false }
        if selectionMIME?.hasPrefix("image/webp") == true { return false }
        return true
    }

    func hasLeadingText(itemCount: Int, isGrouped: Bool, singleItemCanHaveCaption: Bool,
                        projectedCaption: TelegramFormattedText) -> Bool {
        !isGrouped && !projectedCaption.text.isEmpty &&
            (itemCount > 1 || (self == .reference && itemCount == 1 && !singleItemCanHaveCaption))
    }
}
