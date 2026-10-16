import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

nonisolated func telegramNotificationEvents(postbox: Postbox, accountID: Int64, ids: [MessageId]) -> Signal<[TelegramNotificationEvent], NoError> {
    postbox.transaction { tx in
        guard !ids.isEmpty, ids.count <= 10_000 else { return [] }
        var uniqueIDs = Set<MessageId>()
        let ids = ids.filter { uniqueIDs.insert($0).inserted }
        guard ids.count <= 1000 else { return [] }
        var events: [TelegramNotificationEvent] = [], groups = Set<String>()
        for id in ids {
            guard id.namespace == Namespaces.Message.Cloud || id.namespace == Namespaces.Message.SecretIncoming,
                  let message = tx.getMessage(id), message.flags.contains(.Incoming),
                  let peer = tx.getPeer(id.peerId), message.text.utf8.count <= 65_536 else { continue }
            let resolved = messagesForNotification(transaction: tx, id: id, alwaysReturnMessage: false)
            guard resolved.notify, !resolved.messages.isEmpty else { continue }
            let secret = peer is TelegramSecretChat
            let channel = peer as? TelegramChannel, group = peer as? TelegramGroup
            let category: TelegramNotificationCategory
            if let channel, case .broadcast = channel.info { category = .channels }
            else if group != nil || channel != nil { category = .groups }
            else if peer is TelegramUser || secret { category = .personal }
            else { continue }
            let titlePeer = secret ? peer.associatedPeerId.flatMap { tx.getPeer($0) } : peer
            let title = titlePeer.map(telegramPeerTitle) ?? "Telegram"
            let caption: Message
            if let key = message.groupingKey {
                caption = resolved.messages.filter { $0.groupingKey == key && $0.id.peerId == id.peerId && $0.threadId == message.threadId }
                    .sorted { $0.index < $1.index }.first { !$0.text.isEmpty } ?? message
            } else { caption = message }
            let captionSettings = messagesForNotification(transaction: tx, id: caption.id, alwaysReturnMessage: false)
            let entities = caption.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.flatMap(\.entities)
            let text = caption.text.utf8.count <= 65_536 ? try? telegramFormattedText(text: caption.text, entities: entities) : nil
            let fallback: String
            if let file = message.media.first as? TelegramMediaFile {
                fallback = file.isVoice ? "Голосовое сообщение" : file.isInstantVideo ? "Видеосообщение" :
                    file.isSticker || file.isAnimatedSticker ? "Стикер" : file.isVideo ? "Видео" : "Файл"
            } else { fallback = message.media.first is TelegramMediaImage ? "Фото" : "Новое сообщение" }
            let ordinaryThread = channel?.flags.contains(.isForum) == true && message.threadId.map { $0 > 0 && $0 <= Int64(Int32.max) } == true
                ? message.threadId : nil
            let raw = id.peerId.id._internalGetInt64Value()
            let event = TelegramNotificationEvent(accountID: accountID, peerID: id.peerId.toInt64(), namespace: id.namespace,
                messageID: id.id, threadID: ordinaryThread, timestamp: message.timestamp, category: category,
                title: title, text: text, fallback: fallback, incoming: true, serverNotify: true,
                serverPreviews: resolved.displayContents && captionSettings.displayContents,
                serverSilent: resolved.sound == .none || captionSettings.sound == .none, secret: secret,
                protected: message.flags.contains(.CopyProtected) || message.containsSecretMedia || caption.flags.contains(.CopyProtected) || caption.containsSecretMedia ||
                    channel?.flags.contains(.copyProtectionEnabled) == true || group?.flags.contains(.copyProtectionEnabled) == true,
                serviceCodes: id.peerId.namespace == Namespaces.Peer.CloudUser && [Int64(777000),489000].contains(raw),
                groupingKey: message.groupingKey)
            if groups.insert(event.identity).inserted { events.append(event) }
        }
        return events
    }
}

private enum TelegramNotificationSourceUpdate { case events([TelegramNotificationEvent]), overflow }

private nonisolated func telegramNotificationUpdates(account: Account) -> Signal<TelegramNotificationSourceUpdate, NoError> {
    Signal { subscriber in
        let pump = TelegramNotificationBatchPump(read: { ids in
            telegramNotificationEvents(postbox: account.postbox, accountID: account.peerId.toInt64(), ids: ids)
        }, next: { subscriber.putNext(.events($0)) }, overflow: { subscriber.putNext(.overflow) })
        let input = account.stateManager.notificationMessages.start(next: { batches in
            var ids: [MessageId] = []
            collect: for batch in batches where batch.2 {
                for message in batch.0 {
                    ids.append(message.id)
                    if ids.count > 10_000 { break collect }
                }
            }
            pump.offer(ids)
        })
        let disposable = DisposableSet(); disposable.add(pump); disposable.add(input)
        return disposable
    }
}
nonisolated func telegramNotificationUnreadCounts(_ state: ChatListTotalUnreadState) -> [TelegramNotificationCategory: TelegramNotificationUnreadCount] {
    let categories: [(TelegramNotificationCategory, PeerSummaryCounterTags)] = [(.personal, [.contact,.nonContact,.bot]), (.groups, .group), (.channels, .channel)]
    return Dictionary(uniqueKeysWithValues: categories.map { category, tags in
        var messages = 0, chats = 0
        for tag in tags {
            if let counters = state.filteredCounters[tag] {
                guard counters.messageCount >= 0, counters.chatCount >= 0 else {
                    return (category, .init(messages: -1, chats: -1))
                }
                messages += Int(counters.messageCount); chats += Int(counters.chatCount)
            }
        }
        return (category, .init(messages: messages, chats: chats))
    })
}

extension TelegramNotificationController {
    func bind(account: Account?) {
        bind(accountID: account?.peerId.toInt64())
        guard let account else { return }
        let context = contextID
        let subscriptions = DisposableSet()
        subscriptions.add((telegramNotificationUpdates(account: account) |> deliverOnMainQueue).start(next: { [weak self] update in
            switch update {
            case let .events(events): for event in events { self?.receive(event, contextID: context) }
            case .overflow: self?.reportOverflow(contextID: context)
            }
        }))
        subscriptions.add((TelegramEngine(account: account).data.subscribe(TelegramEngine.EngineData.Item.Messages.TotalReadCounters())
            |> deliverOnMainQueue |> map { telegramNotificationUnreadCounts($0._asCounters()) }).start(next: { [weak self] counts in
                self?.receiveUnread(counts, contextID: context)
            }))
        source.set(subscriptions)
    }
}
