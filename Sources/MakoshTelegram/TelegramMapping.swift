import Foundation
import TelegramCore
import Postbox

func telegramPeerTitle(_ peer: Peer) -> String {
    if let user = peer as? TelegramUser { return [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
    if let group = peer as? TelegramGroup { return group.title }
    if let channel = peer as? TelegramChannel { return channel.title }
    return "Диалог \(peer.id.toInt64())"
}

extension TelegramMessage {
    init(_ entry: MessageHistoryEntry, accountID: Int64) {
        self.init(entry.message, isRead: entry.isRead, accountID: accountID)
    }

    init(_ message: Message, isRead: Bool? = nil, accountID: Int64? = nil) {
        self.init(id: "\(message.id.peerId.toInt64()):\(message.id.namespace):\(message.id.id)",
            date: Date(timeIntervalSince1970: TimeInterval(message.timestamp)), text: message.text,
            author: message.author.map(telegramPeerTitle) ?? "Telegram", isOutgoing: telegramMessageIsOutgoing(message, accountID: accountID),
            delivery: telegramMessageDelivery(message, isRead: isRead, accountID: accountID))
        attachments = telegramAttachments(message).map(\.attachment)
        let visual = attachments.first.map { $0.kind == .photo || $0.playback == .video } == true
        let webm = (message.media.first as? TelegramMediaFile)?.mimeType.lowercased() == "video/webm"
        captionAboveMedia = visual && !webm && message.attributes.contains { $0 is InvertMediaMessageAttribute }
        actionMetadata = telegramMessageActionMetadata(message)
        albumGroupID = message.groupInfo?.stableId
        nativeGroupingKey = message.groupingKey
        canGroupMedia = !message.containsSecretMedia && !attachments.contains { $0.kind == .unsupported }
    }
}

@MainActor func telegramMessagePreview(_ message: Message?) -> String {
    guard let message else { return "" }
    let entities = message.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.flatMap(\.entities)
    guard let value = try? telegramFormattedText(text: message.text, entities: entities) else {
        return "Форматирование сообщения недоступно"
    }
    return TelegramMessagePresentation.plainText(value)
}
