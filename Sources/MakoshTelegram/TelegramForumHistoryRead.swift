import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

nonisolated func telegramForumHistoryReadData(postbox: Postbox, target: TelegramHistoryReadTarget)
    -> Signal<ChatReplyThreadMessage?, NoError> {
    postbox.transaction { transaction in
        let peerID = PeerId(target.context.chatID)
        guard let threadID = target.context.threadID, threadID > 0, threadID <= Int64(Int32.max),
              peerID.namespace == Namespaces.Peer.CloudChannel,
              target.index.id.peerId == peerID,
              let peer = transaction.getPeer(peerID) as? TelegramChannel,
              peer.flags.contains(.isForum), !peer.flags.contains(.isMonoforum),
              case .group = peer.info, peer.participationStatus == .member,
              peer.bannedRights?.flags.contains(.banReadMessages) != true,
              peer.defaultBannedRights?.flags.contains(.banReadMessages) != true,
              (transaction.getPeerCachedData(peerId: peerID) as? CachedChannelData)?.isNotAccessible != true,
              telegramForumSendTopic(transaction: transaction, chatID: peerID.toInt64(), threadID: threadID) != nil,
              let message = transaction.getMessage(target.index.id),
              message.threadId == threadID,
              telegramHistoryReadIndex(message) == target.index else { return nil }
        // Use the engine's normalized forum input. Its context reads the current
        // topic counters and holes rather than deriving a peer-wide read index.
        return ChatReplyThreadMessage(peerId: peerID, threadId: threadID, channelMessageId: nil,
            isChannelPost: false, isForumPost: true, isMonoforumPost: false, maxMessage: nil,
            maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0,
            initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false)
    }
}
