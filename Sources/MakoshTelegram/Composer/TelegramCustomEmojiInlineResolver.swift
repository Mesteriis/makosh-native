import Foundation
import TelegramCore
import SwiftSignalKit

@MainActor protocol TelegramCustomEmojiInlineResolverProvider: AnyObject {
    func resolveDescriptors(fileIDs: [Int64]) -> Signal<[Int64: TelegramCustomEmojiDescriptor], NoError>
}
extension TelegramCustomEmojiPlaybackContext {
    // A rendering descriptor is not outgoing authority. Native enqueue still
    // validates the full account-scoped cached media in its transaction.
    func resolveDescriptors(fileIDs: [Int64]) -> Signal<[Int64: TelegramCustomEmojiDescriptor], NoError> {
        guard isValid, accountID == provider.accountID, !fileIDs.isEmpty, fileIDs.count <= 1024,
              !fileIDs.contains(0), let resolver = provider as? any TelegramCustomEmojiInlineResolverProvider else {
            return .single([:])
        }
        let requested = Set(fileIDs), ids = Array(requested).sorted()
        return resolver.resolveDescriptors(fileIDs: ids)
            |> deliverOnMainQueue
            |> map { [weak self] values in
                MainActor.assumeIsolated {
                    guard let self, self.isValid, self.accountID == self.provider.accountID else { return [:] }
                    return values.filter { requested.contains($0.key) && $0.value.fileID == $0.key }
                }
            }
    }
}
extension TelegramCustomEmojiEngineResourceProvider: TelegramCustomEmojiInlineResolverProvider {
    func resolveDescriptors(fileIDs: [Int64]) -> Signal<[Int64: TelegramCustomEmojiDescriptor], NoError> {
        telegramCustomEmojiInlineDescriptors(engine: engine, fileIDs: fileIDs)
    }
}
private nonisolated func telegramCustomEmojiInlineDescriptors(engine: TelegramEngine, fileIDs: [Int64])
    -> Signal<[Int64: TelegramCustomEmojiDescriptor], NoError> {
    let requested = Set(fileIDs)
    return engine.stickers.resolveInlineStickers(fileIds: fileIDs)
        |> map { files in
            var result: [Int64: TelegramCustomEmojiDescriptor] = [:]
            for (id, file) in files where requested.contains(id) {
                if let descriptor = try? TelegramCustomEmojiDescriptor(file: file), descriptor.fileID == id {
                    result[id] = descriptor
                }
            }
            return result
        } |> deliverOnMainQueue
}
