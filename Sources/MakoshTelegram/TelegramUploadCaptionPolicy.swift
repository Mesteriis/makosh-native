import Foundation
import Postbox
import TelegramCore

/// Frozen only for new preparations. Capabilities refer to the final File
/// payload, so a misleading picker extension cannot change message cardinality.
public struct TelegramUploadCaptionPolicy: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let itemID: UUID
        let fileCanHaveCaption: Bool
        private enum CodingKeys: String, CodingKey { case itemID, fileCanHaveCaption }
        init(itemID: UUID, fileCanHaveCaption: Bool) { self.itemID = itemID; self.fileCanHaveCaption = fileCanHaveCaption }
        init(from decoder: any Decoder) throws {
            try captionPolicyFields(decoder, expected: ["itemID", "fileCanHaveCaption"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemID = try c.decode(UUID.self, forKey: .itemID)
            fileCanHaveCaption = try c.decode(Bool.self, forKey: .fileCanHaveCaption)
        }
    }
    public let maximumUTF16Count: Int
    let items: [Item]
    public init(maximumUTF16Count: Int) throws {
        guard TelegramUploadCaptionLimit.isValid(maximumUTF16Count) else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        self.maximumUTF16Count = maximumUTF16Count; items = []
    }
    private init(maximumUTF16Count: Int, items: [Item]) { self.maximumUTF16Count = maximumUTF16Count; self.items = items }
    private enum CodingKeys: String, CodingKey { case maximumUTF16Count, items }
    public init(from decoder: any Decoder) throws {
        try captionPolicyFields(decoder, expected: ["maximumUTF16Count", "items"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maximumUTF16Count = try c.decode(Int.self, forKey: .maximumUTF16Count)
        items = try c.decode([Item].self, forKey: .items)
        guard TelegramUploadCaptionLimit.isValid(maximumUTF16Count) else { throw TelegramPendingUploadPersistenceError.incompatibleData }
    }
    func isValid(for ids: [UUID]) -> Bool {
        TelegramUploadCaptionLimit.isValid(maximumUTF16Count) && !ids.isEmpty && items.map(\.itemID) == ids && Set(ids).count == ids.count
    }
    func reordered(_ ids: [UUID]) throws -> Self {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0) })
        let ordered = ids.compactMap { byID[$0] }
        guard ordered.count == ids.count, Set(ids).count == ids.count else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        return .init(maximumUTF16Count: maximumUTF16Count, items: ordered)
    }
    func binding(_ staged: [TelegramUploadBatchItem]) throws -> Self {
        let bound = try staged.map { item -> Item in
            guard let fileItem = item.presented(as: .file) else { throw TelegramPendingUploadPersistenceError.incompatibleData }
            try TelegramUploadFileIO.validateOwnedStage(fileItem.file)
            guard let media = telegramUploadMedia(fileItem.file, sourceFacts: fileItem.sourceFacts)?.1.media else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            return .init(itemID: item.id, fileCanHaveCaption: telegramUploadMediaCanHaveCaption(media))
        }
        guard items.isEmpty || items == bound else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        return .init(maximumUTF16Count: maximumUTF16Count, items: bound)
    }
    func appending(_ staged: [TelegramUploadBatchItem]) throws -> Self {
        guard isValid(for: items.map(\.itemID)), !staged.isEmpty,
              Set(items.map(\.itemID)).isDisjoint(with: Set(staged.map(\.id))) else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        let addition = try Self(maximumUTF16Count: maximumUTF16Count).binding(staged)
        let result = Self(maximumUTF16Count: maximumUTF16Count, items: items + addition.items)
        guard result.isValid(for: result.items.map(\.itemID)) else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        return result
    }
    func canHaveCaption(itemID: UUID, mode: TelegramUploadMode) -> Bool {
        mode != .file || items.first(where: { $0.itemID == itemID })?.fileCanHaveCaption == true
    }
}

private struct CaptionPolicyField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func captionPolicyFields(_ decoder: any Decoder, expected: Set<String>) throws {
    let c = try decoder.container(keyedBy: CaptionPolicyField.self)
    guard Set(c.allKeys.map(\.stringValue)) == expected else { throw TelegramPendingUploadPersistenceError.incompatibleData }
}

func telegramUploadMediaCanHaveCaption(_ media: any Media) -> Bool {
    if media is TelegramMediaImage { return true }
    guard let file = media as? TelegramMediaFile else { return false }
    return !file.mimeType.hasPrefix("image/webp") && !file.isStaticSticker && !file.isAnimatedSticker && !file.isVoice && !file.isInstantVideo
}
