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
    }
}
