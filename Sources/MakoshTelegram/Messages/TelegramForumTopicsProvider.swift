import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

nonisolated func telegramForumTopicsSignal(postbox: Postbox, accountID: Int64, chatID: Int64)
    -> Signal<Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError>, NoError> {
    let peerID = PeerId(chatID)
    guard peerID.namespace == Namespaces.Peer.CloudChannel else {
        return .single(.failure(.incompatible)) |> deliverOnMainQueue
    }
    let peerKey = PostboxViewKey.basicPeer(peerID)
    let topicsKey = PostboxViewKey.messageHistoryThreadIndex(id: peerID,
        summaryComponents: ChatListEntrySummaryComponents(components: [:]))
    return postbox.combinedView(keys: [peerKey, topicsKey]) |> map { combined -> Result<TelegramForumTopicsSnapshot, TelegramForumTopicsError> in
        // The thread-index view does not replay a pure peer update. Its cached
        // peer must not keep a converted ordinary chat/monoforum in this list.
        guard let peer = (combined.views[peerKey] as? BasicPeerView)?.peer as? TelegramChannel,
              peer.id == peerID, peer.flags.contains(.isForum), !peer.flags.contains(.isMonoforum),
              case .group = peer.info else { return .failure(.incompatible) }
        guard let view = combined.views[topicsKey] as? MessageHistoryThreadIndexView else {
            return .failure(.unavailable)
        }
        let notificationSettings = (combined.views[peerKey] as? BasicPeerView)?.notificationSettings
            as? TelegramPeerNotificationSettings
        var topics: [TelegramForumTopic] = [], ids: Set<Int64> = []
        for item in view.items {
            // Native topic APIs take Int32; never alias an out-of-range id by
            // clamping. General is the valid topic id 1.
            guard item.id > 0, item.id <= Int64(Int32.max), ids.insert(item.id).inserted,
                  item.pinnedIndex.map({ $0 >= 0 }) ?? true,
                  let data = telegramForumTopicData(item.info), data.incomingUnreadCount >= 0 else {
                return .failure(.incompatible)
            }
            let draft: TelegramFormattedText?
            do { draft = try telegramForumTopicDraft(item.embeddedInterfaceState) }
            catch { return .failure(.incompatible) }
            let muted: Bool
            switch data.notificationSettings.muteState {
            case .muted: muted = true
            case .unmuted: muted = false
            case .default:
                if let notificationSettings, case .muted = notificationSettings.muteState { muted = true }
                else { muted = false }
            }
            topics.append(TelegramForumTopic(accountID: accountID, chatID: chatID, threadID: item.id,
                title: data.info.title, iconFileID: data.info.icon, iconColor: data.info.iconColor,
                unreadCount: data.incomingUnreadCount, isMarkedUnread: data.isMarkedUnread,
                isClosed: data.isClosed, isHidden: data.isHidden, isOwnedByMe: data.isOwnedByMe,
                pinnedIndex: item.pinnedIndex,
                lastMessage: item.topMessage.map { TelegramMessage($0, accountID: accountID) },
                draft: draft, isMuted: muted))
        }
        // Preserve native pin/latest-message ordering and exact read titles.
        // Postbox's managed hole service loads subsequent native 100-item pages.
        return .success(TelegramForumTopicsSnapshot(accountID: accountID, chatID: chatID,
            topics: topics, isLoading: view.isLoading))
    } |> deliverOnMainQueue
}

private nonisolated func telegramForumTopicDraft(_ state: StoredPeerChatInterfaceState?) throws -> TelegramFormattedText? {
    guard let state, state.overrideChatTimestamp != nil else { return nil }
    // Reuse the existing server-draft native byte boundary before legacy decode.
    guard (state.data?.count ?? 0) <= 512 * 1024,
          let opaque = _internal_decodeStoredChatInterfaceState(state: state) else {
        throw TelegramForumTopicsError.incompatible
    }
    guard let input = opaque.synchronizeableInputState else { return nil }
    return try telegramFormattedText(text: input.text, entities: input.entities)
}
