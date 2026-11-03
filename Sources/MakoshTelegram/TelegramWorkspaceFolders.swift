import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

public struct TelegramWorkspaceFolder: Identifiable, Equatable, Sendable {
    public let id: Int32
    public let title: String
    public init(id: Int32, title: String) { self.id = id; self.title = title }
}

/// Folder rules are evaluated by Postbox across the complete folder, before paging.
/// Explicit inclusions/exclusions and pinned ordering remain native predicate inputs.
nonisolated func telegramWorkspaceFolderPredicate(_ filter: ChatListFilter?) -> ChatListFilterPredicate? {
    guard case let .filter(_, _, _, rules) = filter else { return nil }
    let mentions = ChatListMessageTagSummaryResultCalculation(
        addCount: ChatListMessageTagSummaryResultComponent(tag: .unseenPersonalMessage, namespace: Namespaces.Message.Cloud),
        subtractCount: ChatListMessageTagActionsSummaryResultComponent(type: PendingMessageActionType.consumeUnseenPersonalMessage, namespace: Namespaces.Message.Cloud))
    return ChatListFilterPredicate(includePeerIds: Set(rules.includePeers.peers),
        excludePeerIds: Set(rules.excludePeers), pinnedPeerIds: rules.includePeers.pinnedPeers,
        messageTagSummary: rules.excludeRead || rules.excludeMuted ? mentions : nil,
        includeAdditionalPeerGroupIds: rules.excludeArchived ? [] : [Namespaces.PeerGroup.archive]) { peer, muted, unread, contact, mention in
            if rules.excludeRead && !unread && mention != true { return false }
            if rules.excludeMuted && muted && mention != true { return false }
            let category: ChatListFilterPeerCategories
            switch peer {
            case let user as TelegramUser: category = user.botInfo != nil ? .bots : contact ? .contacts : .nonContacts
            case is TelegramSecretChat: category = contact ? .contacts : .nonContacts
            case is TelegramGroup: category = .groups
            case let channel as TelegramChannel:
                if case .group = channel.info { category = .groups } else { category = .channels }
            default: return false
            }
            return rules.categories.contains(category)
        }
}

nonisolated func telegramWorkspaceFolderUpdates(account: Account) -> Signal<[ChatListFilter], NoError> {
    TelegramEngine(account: account).peers.updatedChatListFilters()
}

nonisolated func telegramWorkspaceChatPage(account: Account, group: PeerGroupId, filter: ChatListFilter?, anchor: ChatListIndex?) -> Signal<TelegramChatPageProjection, NoError> {
    let predicate = telegramWorkspaceFolderPredicate(filter)
    let signal = anchor.map { account.viewTracker.aroundChatListView(groupId: group, filterPredicate: predicate, index: $0, count: 50) }
        ?? account.viewTracker.tailChatListView(groupId: group, filterPredicate: predicate, count: 50)
    return telegramProjectChatPage(account: account, signal: signal)
}
