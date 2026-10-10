import Foundation
import TelegramCore
import Postbox

public enum TelegramFormattedTextError: Error, LocalizedError {
    case invalid
    public var errorDescription: String? { "Некорректные границы или тип форматирования Telegram." }
}

/// Full native sticker-pack provenance; access hashes are never displayed or logged.
public enum TelegramStickerPackReference: Codable, Sendable, Hashable {
    case id(id: Int64, accessHash: Int64), name(String), animatedEmoji, dice(String)
    case animatedEmojiAnimations, premiumGifts, emojiGenericAnimations, iconStatusEmoji
    case iconTopicEmoji, iconChannelStatusEmoji, tonGifts
    public static func == (lhs: Self, rhs: Self) -> Bool { exactEntityEncoding(lhs, rhs) }
    public func hash(into hasher: inout Hasher) { hashEntityEncoding(self, into: &hasher) }
}
public enum TelegramTextEntityKind: Codable, Sendable, Hashable {
    case unknown, mention, hashtag, botCommand, url, email, bold, italic, code
    case pre(language: String?), textURL(url: String), textMention(peerID: Int64)
    case phoneNumber, strikethrough, blockQuote(isCollapsed: Bool), underline, bankCard, spoiler
    case customEmoji(stickerPack: TelegramStickerPackReference?, fileID: Int64), custom(type: Int32)
    public static func == (lhs: Self, rhs: Self) -> Bool { exactEntityEncoding(lhs, rhs) }
    public func hash(into hasher: inout Hasher) { hashEntityEncoding(self, into: &hasher) }
}
private func hashEntityEncoding<T: Encodable>(_ value: T, into hasher: inout Hasher) {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    hasher.combine(try? encoder.encode(value))
}
private func exactEntityEncoding<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    // These DTOs contain only finite integers, strings and enums; encoding cannot
    // fail for a valid value. Fail closed rather than normalizing Unicode strings.
    guard let a = try? encoder.encode(lhs), let b = try? encoder.encode(rhs) else { return false }
    return a == b
}
public struct TelegramTextEntity: Hashable, Codable, Sendable {
    public let offset: Int
    public let length: Int
    public let kind: TelegramTextEntityKind
    public init(offset: Int, length: Int, kind: TelegramTextEntityKind) {
        self.offset = offset; self.length = length; self.kind = kind
    }
}
public struct TelegramFormattedText: Hashable, Codable, Sendable {
    public let text: String
    public let entities: [TelegramTextEntity]
    public init(text: String, entities: [TelegramTextEntity] = []) throws {
        let count = text.utf16.count
        guard count <= Int(Int32.max), entities.count <= 4096 else { throw TelegramFormattedTextError.invalid }
        var boundaries: Set<Int> = [0], cursor = 0
        for scalar in text.unicodeScalars {
            cursor += scalar.value > 0xffff ? 2 : 1; boundaries.insert(cursor)
        }
        for entity in entities {
            guard entity.offset >= 0, entity.length > 0,
                  entity.offset <= count, entity.length <= count - entity.offset,
                  boundaries.contains(entity.offset), boundaries.contains(entity.offset + entity.length) else {
                throw TelegramFormattedTextError.invalid
            }
        }
        // Partial crossings cannot be represented as Telegram nested entities.
        for (index, a) in entities.enumerated() {
            for b in entities.dropFirst(index + 1) {
                let ae = a.offset + a.length, be = b.offset + b.length
                if (a.offset < b.offset && b.offset < ae && ae < be) ||
                    (b.offset < a.offset && a.offset < be && be < ae) { throw TelegramFormattedTextError.invalid }
            }
        }
        self.text = text; self.entities = entities
    }
    private enum CodingKeys: String, CodingKey { case text, entities }
    public init(from decoder: Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(text: values.decode(String.self, forKey: .text),
                          entities: values.decode([TelegramTextEntity].self, forKey: .entities))
        } catch { throw TelegramFormattedTextError.invalid }
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(Data(text.utf8)); hasher.combine(entities)
    }
    /// Upstream's API converter drops these kinds. Retain them for reading, but
    /// refuse a mutation that would silently flatten their semantics.
    public var isEditable: Bool {
        entities.allSatisfy {
            switch $0.kind { case .unknown, .custom, .phoneNumber: false; default: true }
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.entities == rhs.entities
    }
    func engineEntities() -> [MessageTextEntity] {
        entities.map { MessageTextEntity(range: $0.offset..<($0.offset + $0.length), type: $0.kind.native) }
    }
}
public func telegramFormattedText(text: String, entities: [MessageTextEntity]) throws -> TelegramFormattedText {
    let count = text.utf16.count
    var result: [TelegramTextEntity] = []
    for entity in entities {
        guard entity.range.lowerBound >= 0, entity.range.upperBound <= count,
              entity.range.upperBound > entity.range.lowerBound else { throw TelegramFormattedTextError.invalid }
        result.append(TelegramTextEntity(offset: entity.range.lowerBound,
            length: entity.range.upperBound - entity.range.lowerBound, kind: TelegramTextEntityKind(entity.type)))
    }
    return try TelegramFormattedText(text: text, entities: result)
}

private extension TelegramStickerPackReference {
    init(_ value: StickerPackReference) {
        switch value {
        case let .id(id, accessHash): self = .id(id: id, accessHash: accessHash)
        case let .name(name): self = .name(name)
        case .animatedEmoji: self = .animatedEmoji
        case let .dice(value): self = .dice(value)
        case .animatedEmojiAnimations: self = .animatedEmojiAnimations
        case .premiumGifts: self = .premiumGifts
        case .emojiGenericAnimations: self = .emojiGenericAnimations
        case .iconStatusEmoji: self = .iconStatusEmoji
        case .iconTopicEmoji: self = .iconTopicEmoji
        case .iconChannelStatusEmoji: self = .iconChannelStatusEmoji
        case .tonGifts: self = .tonGifts
        }
    }
    var native: StickerPackReference {
        switch self {
        case let .id(id, accessHash): return .id(id: id, accessHash: accessHash)
        case let .name(name): return .name(name)
        case .animatedEmoji: return .animatedEmoji
        case let .dice(value): return .dice(value)
        case .animatedEmojiAnimations: return .animatedEmojiAnimations
        case .premiumGifts: return .premiumGifts
        case .emojiGenericAnimations: return .emojiGenericAnimations
        case .iconStatusEmoji: return .iconStatusEmoji
        case .iconTopicEmoji: return .iconTopicEmoji
        case .iconChannelStatusEmoji: return .iconChannelStatusEmoji
        case .tonGifts: return .tonGifts
        }
    }
}
private extension TelegramTextEntityKind {
    init(_ value: MessageTextEntityType) {
        switch value {
        case .Unknown: self = .unknown
        case .Mention: self = .mention
        case .Hashtag: self = .hashtag
        case .BotCommand: self = .botCommand
        case .Url: self = .url
        case .Email: self = .email
        case .Bold: self = .bold
        case .Italic: self = .italic
        case .Code: self = .code
        case let .Pre(language): self = .pre(language: language)
        case let .TextUrl(url): self = .textURL(url: url)
        case let .TextMention(peerId): self = .textMention(peerID: peerId.toInt64())
        case .PhoneNumber: self = .phoneNumber
        case .Strikethrough: self = .strikethrough
        case let .BlockQuote(collapsed): self = .blockQuote(isCollapsed: collapsed)
        case .Underline: self = .underline
        case .BankCard: self = .bankCard
        case .Spoiler: self = .spoiler
        case let .CustomEmoji(pack, fileId): self = .customEmoji(stickerPack: pack.map(TelegramStickerPackReference.init), fileID: fileId)
        case let .Custom(type): self = .custom(type: type)
        }
    }
    var native: MessageTextEntityType {
        switch self {
        case .unknown: return .Unknown
        case .mention: return .Mention
        case .hashtag: return .Hashtag
        case .botCommand: return .BotCommand
        case .url: return .Url
        case .email: return .Email
        case .bold: return .Bold
        case .italic: return .Italic
        case .code: return .Code
        case let .pre(language): return .Pre(language: language)
        case let .textURL(url): return .TextUrl(url: url)
        case let .textMention(peerID): return .TextMention(peerId: PeerId(peerID))
        case .phoneNumber: return .PhoneNumber
        case .strikethrough: return .Strikethrough
        case let .blockQuote(collapsed): return .BlockQuote(isCollapsed: collapsed)
        case .underline: return .Underline
        case .bankCard: return .BankCard
        case .spoiler: return .Spoiler
        case let .customEmoji(pack, fileID): return .CustomEmoji(stickerPack: pack?.native, fileId: fileID)
        case let .custom(type): return .Custom(type: type)
        }
    }
}
