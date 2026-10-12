import TelegramCore
import Postbox

/// Engine observations, not a device-delivery guarantee. Bot/Saved double
/// checks are reference UI conventions and have deliberately distinct states.
public enum TelegramMessageDelivery: Equatable, Sendable {
    case none, unknown, queued, sending, failed, sent, read, saved, sentToBot
}

func telegramMessageIsOutgoing(_ message: Message, accountID: Int64?) -> Bool {
    if let channel = message.peers[message.id.peerId] as? TelegramChannel, case .broadcast = channel.info { return false }
    guard let accountID else { return !message.flags.contains(.Incoming) }
    return !message.effectivelyIncoming(PeerId(accountID))
}

func telegramMessageDelivery(_ message: Message, isRead: Bool?, accountID: Int64?) -> TelegramMessageDelivery {
    if message.flags.contains(.Failed) { return .failed }
    if message.flags.contains(.Sending) { return .sending }
    if message.flags.contains(.Unsent) { return .queued }
    guard telegramMessageIsOutgoing(message, accountID: accountID) else { return .none }
    guard message.id.namespace == Namespaces.Message.Cloud else { return .unknown }
    // Conservatively suppress read conventions for source-reference messages.
    // Reference also considers pinned/custom modes and crosspost context, which
    // this message-only projection cannot reconstruct.
    if message.attributes.contains(where: { $0 is SourceReferenceMessageAttribute }) { return .sent }
    if let accountID, message.id.peerId.toInt64() == accountID,
       (message.peers[message.id.peerId] as? TelegramUser)?.flags.contains(.isSupport) != true { return .saved }
    if let peer = message.peers[message.id.peerId] as? TelegramUser,
       peer.botInfo != nil, !peer.flags.contains(.isSupport) { return .sentToBot }
    return isRead == true ? .read : .sent
}
