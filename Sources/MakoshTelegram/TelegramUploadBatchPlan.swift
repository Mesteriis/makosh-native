import Foundation
import Postbox
import TelegramCore

struct TelegramUploadQueueID: Codable, Equatable, Hashable, Sendable {
    let peerID: Int64
    let namespace: Int32
    let id: Int32
    init(_ value: MessageId) { peerID = value.peerId.toInt64(); namespace = value.namespace; id = value.id }
    var description: String { "\(peerID):\(namespace):\(id)" }
    var nativeID: MessageId { MessageId(peerId: PeerId(peerID), namespace: namespace, id: id) }
}

/// Stable item identities and caption assignment; random native group keys are
/// supplied once at admission, rather than changing with preview positions.
struct TelegramUploadBatchPlan: Equatable, Sendable {
    struct Message: Equatable, Sendable {
        let itemID: UUID?
        let caption: TelegramFormattedText
        let groupIndex: Int?
        let captionAboveMedia: Bool
        let mediaSpoiler: Bool
    }
    let messages: [Message]
    let groupCount: Int
    init(items: [TelegramUploadBatchItem], isGrouped: Bool, caption: TelegramFormattedText,
         captionAboveMedia: Bool = false, mediaSpoiler: Bool = false, presentation: TelegramUploadPresentation? = nil) throws {
        if items.contains(where: { $0.file.metadata?.voice != nil }) {
            guard items.count == 1, !isGrouped, caption.text.isEmpty, !captionAboveMedia, !mediaSpoiler,
                  presentation == .file, items[0].file.mode == .file, items[0].originalFile == nil else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
        }
        guard !items.isEmpty, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.id != TelegramPendingUploadDraft.zeroUUID }),
              telegramFormattedCaptionCanSend(caption),
              presentation != nil || items.allSatisfy({ $0.file.mode == .file }) || items.allSatisfy({ $0.file.mode != .file }),
              presentation != nil || (!captionAboveMedia && !mediaSpoiler) || items.allSatisfy({ $0.file.mode != .file }),
              presentation == nil || !isGrouped || presentation!.allowsGrouping(items.map {
                  (name: $0.originalFile?.name ?? $0.file.name, isVisual: $0.file.mode != .file, metadata: $0.file.metadata)
              }) else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        let empty = try TelegramFormattedText(text: "")
        let grouped = isGrouped && items.count > 1
        groupCount = grouped ? (items.count + 9) / 10 : 0
        var result: [Message] = []
        let leadingText = !isGrouped && items.count > 1 && !caption.text.isEmpty
        if leadingText {
            result.append(.init(itemID: nil, caption: caption, groupIndex: nil, captionAboveMedia: false, mediaSpoiler: false))
        }
        let chunkSize = grouped ? 10 : items.count
        for start in stride(from: 0, to: items.count, by: chunkSize) {
            let end = min(start + chunkSize, items.count)
            let captionIndex = items[start].file.mode == .file ? end - 1 : start
            for index in start..<end {
                result.append(.init(itemID: items[index].id, caption: !leadingText && index == captionIndex ? caption : empty,
                    groupIndex: grouped ? start / 10 : nil, captionAboveMedia: presentation == .file ? false : captionAboveMedia, mediaSpoiler: mediaSpoiler))
            }
        }
        messages = result
    }
}
