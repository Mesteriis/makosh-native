import Foundation
import TelegramCore
import Postbox

struct TelegramCustomEmojiRegistry {
    let accountID: Int64
    let files: [Int64: TelegramMediaFile]
    let descriptors: [Int64: TelegramCustomEmojiDescriptor]
    private let encodedFiles: [Int64: Data]

    init(accountID: Int64, files: [TelegramMediaFile]) throws {
        guard accountID != 0, PeerId(accountID).namespace == Namespaces.Peer.CloudUser,
              files.count <= 1024 else { throw TelegramCustomEmojiError.invalid }
        var native: [Int64: TelegramMediaFile] = [:], descriptors: [Int64: TelegramCustomEmojiDescriptor] = [:]
        var encoded: [Int64: Data] = [:]
        for file in files {
            let descriptor = try TelegramCustomEmojiDescriptor(file: file)
            let bytes = PostboxEncoder().encodeObjectToRawData(file).data
            if let previous = encoded[descriptor.fileID], previous != bytes { throw TelegramCustomEmojiError.invalid }
            native[descriptor.fileID] = file; descriptors[descriptor.fileID] = descriptor; encoded[descriptor.fileID] = bytes
        }
        self.accountID = accountID
        self.files = native; self.descriptors = descriptors; encodedFiles = encoded
    }
    var inlineStickers: [MediaId: Media] {
        Dictionary(files.values.map { ($0.fileId, $0 as Media) }, uniquingKeysWith: { _, last in last })
    }

    func matchesCachedFile(_ file: TelegramMediaFile) -> Bool {
        encodedFiles[file.fileId.id] == PostboxEncoder().encodeObjectToRawData(file).data
    }
}
nonisolated func telegramCustomEmojiAdmission(formatted: TelegramFormattedText, registry: TelegramCustomEmojiRegistry,
    transaction: Transaction, accountPeerID: PeerId, targetPeerID: PeerId) -> Bool {
    guard formatted.isEditable, registry.accountID == accountPeerID.toInt64(),
          let ownUser = transaction.getPeer(accountPeerID) as? TelegramUser,
          ownUser.id.namespace == Namespaces.Peer.CloudUser else { return false }
    let entities = formatted.entities.filter { if case .customEmoji = $0.kind { return true }; return false }
    let ids = Set(entities.compactMap { entity -> Int64? in
        if case let .customEmoji(_, fileID) = entity.kind { return fileID }
        return nil
    })
    guard ids == Set(registry.files.keys) else { return false }
    var graphemeBoundaries: Set<Int> = [0], offset = 0
    for character in formatted.text {
        offset += String(character).utf16.count
        graphemeBoundaries.insert(offset)
    }
    var previousEnd = 0
    for entity in entities.sorted(by: { $0.offset < $1.offset }) {
        guard entity.offset >= previousEnd,
              graphemeBoundaries.contains(entity.offset),
              graphemeBoundaries.contains(entity.offset + entity.length) else { return false }
        previousEnd = entity.offset + entity.length
        let substring = (formatted.text as NSString).substring(with: .init(location: entity.offset, length: entity.length))
        guard TelegramCustomEmojiDescriptor.isEmojiFallback(substring),
              case let .customEmoji(_, fileID) = entity.kind,
              let frozen = registry.files[fileID], let descriptor = registry.descriptors[fileID],
              let cached = transaction.getMedia(frozen.fileId) as? TelegramMediaFile,
              registry.matchesCachedFile(cached) else { return false }
        if descriptor.isPremium && !ownUser.flags.contains(.isPremium) && targetPeerID != accountPeerID { return false }
    }
    return true
}

nonisolated func telegramCustomEmojiCachedAdmission(formatted: TelegramFormattedText, transaction: Transaction,
    accountID: Int64, chatID: Int64) -> Bool {
    let ids = Set(formatted.entities.compactMap { entity -> Int64? in
        if case let .customEmoji(_, fileID) = entity.kind { return fileID }; return nil
    })
    guard ids.count <= 1024 else { return false }
    guard !ids.isEmpty else { return formatted.isEditable }
    let files = ids.compactMap { transaction.getMedia(MediaId(namespace: Namespaces.Media.CloudFile, id: $0)) as? TelegramMediaFile }
    guard files.count == ids.count,
          let registry = try? TelegramCustomEmojiRegistry(accountID: accountID, files: files) else { return false }
    return telegramCustomEmojiAdmission(formatted: formatted, registry: registry, transaction: transaction,
        accountPeerID: PeerId(accountID), targetPeerID: PeerId(chatID))
}
