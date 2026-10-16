import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

struct TelegramChatPageProjection {
    let chats: [TelegramChat]
    let previous: ChatListIndex?, next: ChatListIndex?
    let isLoading: Bool
}
struct TelegramHistoryPageProjection {
    let messages: [TelegramMessage]
    let sources: [TelegramAttachmentSource]
    let readIndexes: [String: MessageIndex]
    let previous: MessageIndex?, next: MessageIndex?
    let isLoading: Bool, holeEarlier: Bool, holeLater: Bool
}

/// Native view queues perform decoding, fingerprints and attachment projection.
/// MainActor receives the resulting snapshot and checks its presentation token.
nonisolated func telegramProjectChatPage(account: Account,
    signal: Signal<(ChatListView, ViewUpdateType), NoError>) -> Signal<TelegramChatPageProjection, NoError> {
    signal |> map { value in
        let view = value.0
        let chats = view.entries.reversed().compactMap { entry -> TelegramChat? in
            guard case let .MessageEntry(data) = entry, let peer = data.renderedPeer.peer else { return nil }
            return TelegramChat(id: peer.id.toInt64(), title: telegramPeerTitle(peer),
                preview: telegramMessagePreview(data.messages.last), unreadCount: Int(data.readState?.state.count ?? 0),
                presence: telegramChatPresence(presence: data.presence, accountID: account.peerId.toInt64(),
                    peerID: peer.id.toInt64(), serverTimeOffset: account.network.globalTimeDifference))
        }
        let waiting = view.entries.contains { if case .HoleEntry = $0 { return true }; return false }
        return .init(chats: chats, previous: view.earlierIndex, next: view.laterIndex, isLoading: waiting)
    }
}
nonisolated func telegramProjectHistoryPage(account: Account, chatID: Int64, threadID: Int64?,
    index: MessageHistoryAnchorIndex) -> Signal<TelegramHistoryPageProjection, NoError> {
    account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: PeerId(chatID), threadId: threadID),
        index: index, anchorIndex: index, count: 50, fixedCombinedReadStates: nil)
    |> map { value in
        let view = value.0
        let messages = view.entries.map { TelegramMessage($0, accountID: account.peerId.toInt64()) }
        let readIndexes = Dictionary(uniqueKeysWithValues: view.entries.compactMap { entry -> (String, MessageIndex)? in
            guard let index = telegramHistoryReadIndex(entry.message) else { return nil }
            let id = "\(entry.message.id.peerId.toInt64()):\(entry.message.id.namespace):\(entry.message.id.id)"
            return (id, index)
        })
        return .init(messages: messages, sources: view.entries.flatMap { telegramAttachments($0.message) },
            readIndexes: readIndexes, previous: view.earlierId, next: view.laterId,
            isLoading: view.isLoading || view.isLoadingEarlier ||
                (view.earlierId == nil && view.holeEarlier) || (view.laterId == nil && view.holeLater),
            holeEarlier: view.holeEarlier, holeLater: view.holeLater)
    }
}
