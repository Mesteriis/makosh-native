import Foundation

public enum TelegramCustomEmojiInsertion {
    public static func applying(_ emoji: TelegramCustomEmojiDescriptor, to input: TelegramComposerInput) throws -> TelegramComposerInput {
        let original = input.formattedText, selection = input.selection
        guard original.isEditable, TelegramCustomEmojiDescriptor.isEmojiFallback(emoji.fallbackText) else {
            throw TelegramCustomEmojiError.invalid
        }
        let start = selection.location, end = start + selection.length
        // Composer selections validate scalar boundaries. An emoji insertion
        // must additionally preserve a complete grapheme at each selection edge.
        let boundaries = Set(original.text.indices.map { $0.utf16Offset(in: original.text) } + [original.text.utf16.count])
        guard boundaries.contains(start), boundaries.contains(end) else { throw TelegramCustomEmojiError.invalid }
        let replacementCount = emoji.fallbackText.utf16.count, delta = replacementCount - selection.length
        var entities: [TelegramTextEntity] = []
        for entity in original.entities {
            let a = entity.offset, b = a + entity.length
            if b <= start {
                entities.append(entity)
            } else if a >= end {
                entities.append(.init(offset: a + delta, length: entity.length, kind: entity.kind))
            } else if start <= a && end >= b {
                // A fully replaced semantic run contributes no surviving entity.
                continue
            } else {
                switch entity.kind {
                case .bold, .italic, .underline, .strikethrough, .spoiler, .code, .pre, .blockQuote:
                    if a < start && b > end {
                        entities.append(.init(offset: a, length: entity.length + delta, kind: entity.kind))
                    } else if a < start {
                        entities.append(.init(offset: a, length: start - a, kind: entity.kind))
                    } else if b > end {
                        entities.append(.init(offset: start + replacementCount, length: b - end, kind: entity.kind))
                    }
                default:
                    // A partial link, mention or custom emoji would acquire a
                    // different meaning. Keep the entire input unchanged instead.
                    throw TelegramCustomEmojiError.invalid
                }
            }
        }
        let lower = String.Index(utf16Offset: start, in: original.text)
        let upper = String.Index(utf16Offset: end, in: original.text)
        var text = original.text
        text.replaceSubrange(lower..<upper, with: emoji.fallbackText)
        entities.append(.init(offset: start, length: replacementCount,
            kind: .customEmoji(stickerPack: emoji.packReference, fileID: emoji.fileID)))
        return try TelegramComposerInput(formattedText: .init(text: text, entities: entities),
            selection: .init(location: start + replacementCount, length: 0))
    }
}

/// A single native edit request bound to the exact source, selection and chat
/// context that the user picked from. The model additionally admits its draft
/// revision and account before the editor consumes it.
public struct TelegramCustomEmojiInsertionRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let descriptor: TelegramCustomEmojiDescriptor
    public let expectedInput: TelegramComposerInput
    public let contextID: UUID
    public init(id: UUID = UUID(), descriptor: TelegramCustomEmojiDescriptor,
        expectedInput: TelegramComposerInput, contextID: UUID) {
        self.id = id; self.descriptor = descriptor; self.expectedInput = expectedInput; self.contextID = contextID
    }
}
