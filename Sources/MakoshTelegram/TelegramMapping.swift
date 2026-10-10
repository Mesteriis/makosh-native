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
    init(_ message: Message) {
        self.init(id: "\(message.id.peerId.toInt64()):\(message.id.namespace):\(message.id.id)",
            date: Date(timeIntervalSince1970: TimeInterval(message.timestamp)), text: message.text,
            author: message.author.map(telegramPeerTitle) ?? "Telegram", isOutgoing: !message.flags.contains(.Incoming),
            delivery: message.flags.contains(.Failed) ? "Не отправлено" : message.flags.contains(.Unsent) ? "В очереди отправки" : "")
        attachments = telegramAttachments(message).map(\.attachment)
        actionMetadata = telegramMessageActionMetadata(message)
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
