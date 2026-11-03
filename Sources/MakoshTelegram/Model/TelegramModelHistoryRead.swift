import Foundation
import Postbox
import TelegramCore

/// A visible stored message is the history boundary, including outgoing rows:
/// native interactive read also advances preceding incoming messages.
func telegramHistoryReadIndex(_ message: Message) -> MessageIndex? {
    guard message.id.peerId.id._internalGetInt64Value() > 0,
          [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel]
            .contains(message.id.peerId.namespace),
          message.id.namespace == Namespaces.Message.Cloud, message.id.id > 0,
          message.flags.intersection([.Unsent, .Sending, .Failed]).isEmpty else { return nil }
    return MessageIndex(id: message.id, timestamp: message.timestamp)
}

extension TelegramModel {
    // Called only by the guarded account/chat/request history subscription.
    // Its native view can include the associated old peer of a migrated group;
    // keep that exact peer rather than manufacturing a selected-chat index.
    func prepareHistoryReadIndexes(_ entries: [MessageHistoryEntry]) {
        historyReadIndexes = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            guard let index = telegramHistoryReadIndex(entry.message) else { return nil }
            let id = "\(entry.message.id.peerId.toInt64()):\(entry.message.id.namespace):\(entry.message.id.id)"
            return (id, index)
        })
    }

    /// Receives actual viewport observations. Search results never supply read
    /// indexes. Admission is rechecked against the current account/chat/window.
    @discardableResult public func markVisibleHistoryRead(messageIDs: Set<String>,
        context: TelegramHistoryReadContext, windowIsActive: Bool) -> Bool {
        guard context == historyReadContext else { return false }
        #if DEBUG
        if isSyntheticPreview { syntheticHistoryReadWindowActive = windowIsActive }
        #endif
        guard windowIsActive else { return false }
        let displayedIDs = Set(messages.map(\.id))
        guard let index = messageIDs.intersection(displayedIDs).compactMap({ historyReadIndexes[$0] }).max() else { return false }
        return historyRead.apply(TelegramHistoryReadTarget(context: context, index: index))
    }

    #if DEBUG
    func bindSyntheticHistoryRead() {
        historyRead.bind(TelegramSyntheticHistoryReadProvider(model: self))
    }

    func prepareSyntheticHistoryReadIndexes(_ items: [TelegramMessage]) {
        historyReadIndexes = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let metadata = item.actionMetadata,
                  item.delivery != .queued, item.delivery != .sending, item.delivery != .failed else { return nil }
            let index = MessageIndex(id: MessageId(peerId: PeerId(metadata.peerID),
                namespace: metadata.namespace, id: metadata.messageID), timestamp: metadata.messageID)
            return (item.id, index)
        })
    }

    public static func syntheticHistoryReadPreview() -> TelegramModel {
        let model = syntheticPreview()
        model.selectedChatID = model.chats.first?.id
        model.search.messageQuery = "Тестовое сообщение"
        return model
    }
    #endif
}

#if DEBUG
@MainActor private final class TelegramSyntheticHistoryReadProvider: TelegramHistoryReadProvider {
    let accountID: Int64 = -1
    private weak var model: TelegramModel?
    init(model: TelegramModel) { self.model = model }
    func apply(_ target: TelegramHistoryReadTarget, completion: @escaping @MainActor (Bool) -> Void) {
        guard let model else { completion(false); return }
        model.syntheticHistoryReadCount += 1
        model.syntheticHistoryReadLastMessage = target.index.id.id
        completion(true)
    }
}
#endif
