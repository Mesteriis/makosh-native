import Foundation
import TelegramCore
import Postbox

public enum TelegramCustomEmojiError: Error, LocalizedError {
    case invalid, unresolved, disallowed
    public var errorDescription: String? { "Не удалось подтвердить документ или права для эмодзи Telegram." }
}
public enum TelegramCustomEmojiFormat: String, Codable, Hashable, Sendable { case webP, tgs, webM }
public struct TelegramCustomEmojiDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: Int64 { fileID }
    public let fileID: Int64
    public let fallbackText: String
    public let packReference: TelegramStickerPackReference?
    public let format: TelegramCustomEmojiFormat
    public let isPremium: Bool
    public let isSingleColor: Bool

    init(file: TelegramMediaFile) throws {
        guard file.fileId.namespace == Namespaces.Media.CloudFile,
              let resource = file.resource as? CloudDocumentMediaResource,
              resource.fileId == file.fileId.id, resource.datacenterId > 0 else {
            throw TelegramCustomEmojiError.invalid
        }
        let format: TelegramCustomEmojiFormat
        switch file.mimeType {
        case "image/webp": format = .webP
        case "application/x-tgsticker": format = .tgs
        case "video/webm": format = .webM
        default: throw TelegramCustomEmojiError.invalid
        }
        let attributes = file.attributes.compactMap { attribute -> (Bool, Bool, String, StickerPackReference?)? in
            if case let .CustomEmoji(premium, singleColor, alt, pack) = attribute {
                return (premium, singleColor, alt, pack)
            }
            return nil
        }
        guard attributes.count == 1, let attribute = attributes.first else {
            throw TelegramCustomEmojiError.invalid
        }
        // Reuse the existing lossless native pack conversion, including all of
        // its named/default-pack cases, without treating that DTO as authority.
        let converted = try telegramFormattedText(text: attribute.2, entities: [
            MessageTextEntity(range: 0..<attribute.2.utf16.count,
                type: .CustomEmoji(stickerPack: attribute.3, fileId: file.fileId.id))])
        guard case let .customEmoji(packReference, _)? = converted.entities.first?.kind else {
            throw TelegramCustomEmojiError.invalid
        }
        try self.init(fileID: file.fileId.id, fallbackText: attribute.2,
            packReference: packReference, format: format, isPremium: attribute.0, isSingleColor: attribute.1)
    }

    private init(fileID: Int64, fallbackText: String, packReference: TelegramStickerPackReference?,
                 format: TelegramCustomEmojiFormat, isPremium: Bool, isSingleColor: Bool) throws {
        guard fileID != 0, Self.isEmojiFallback(fallbackText) else { throw TelegramCustomEmojiError.invalid }
        self.fileID = fileID; self.fallbackText = fallbackText; self.packReference = packReference
        self.format = format; self.isPremium = isPremium; self.isSingleColor = isSingleColor
    }

    static func isEmojiFallback(_ value: String) -> Bool {
        guard value.count == 1, value.utf16.count <= 256 else { return false }
        let scalars = value.unicodeScalars
        return scalars.contains(where: { ($0.properties.isEmoji && $0.value > 0x7f) || $0.value == 0xfe0f }) &&
            scalars.allSatisfy { $0.properties.isEmoji || $0.value == 0x200d ||
                $0.value == 0xfe0f || $0.value == 0x20e3 || (0xe0020...0xe007f).contains($0.value) }
    }

    private enum CodingKeys: String, CodingKey {
        case fileID, fallbackText, packReference, format, isPremium, isSingleColor
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fileID: values.decode(Int64.self, forKey: .fileID),
            fallbackText: values.decode(String.self, forKey: .fallbackText),
            packReference: values.decodeIfPresent(TelegramStickerPackReference.self, forKey: .packReference),
            format: values.decode(TelegramCustomEmojiFormat.self, forKey: .format),
            isPremium: values.decode(Bool.self, forKey: .isPremium),
            isSingleColor: values.decode(Bool.self, forKey: .isSingleColor))
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fileID == rhs.fileID && lhs.fallbackText.utf8.elementsEqual(rhs.fallbackText.utf8) &&
            lhs.packReference == rhs.packReference && lhs.format == rhs.format &&
            lhs.isPremium == rhs.isPremium && lhs.isSingleColor == rhs.isSingleColor
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(fileID); hasher.combine(Data(fallbackText.utf8)); hasher.combine(packReference)
        hasher.combine(format); hasher.combine(isPremium); hasher.combine(isSingleColor)
    }
}
