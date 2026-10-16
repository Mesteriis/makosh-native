import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

nonisolated func telegramReplyEnqueueMessage(transaction: Transaction, accountID: Int64,
    source: TelegramMessageActionSource, formatted: TelegramFormattedText) -> EnqueueMessage? {
    let id = MessageId(peerId: PeerId(source.peerID), namespace: source.namespace, id: source.messageID)
    guard source.accountID == accountID,
          ([Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(PeerId(source.chatID).namespace) || telegramSecretPeerID(source.chatID) != nil),
          telegramFormattedTextCanPrepare(formatted, transaction: transaction),
          let message = transaction.getMessage(id),
          let fresh = TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message,
              limits: currentLimitsConfiguration(transaction: transaction)), accountID: accountID, chatID: source.chatID)
              .quoting(source.replyQuote, maximumLength: telegramReplyQuoteLimit(transaction: transaction)),
          fresh.canReply, fresh.fingerprint == source.fingerprint, fresh.threadID == source.threadID else { return nil }
    if let id = telegramSecretPeerID(source.chatID) {
        guard source.peerID == source.chatID, source.replyQuote == nil, source.threadID == nil,
              telegramSecretReplySource(message), let state = transaction.getPeerChatState(id) as? SecretChatState,
              let layer = telegramSecretLayer(state), layer >= 46 else { return nil }
    }
    if source.chatID != source.peerID {
        guard let group = transaction.getPeer(id.peerId) as? TelegramGroup,
              group.migrationReference?.peerId == PeerId(source.chatID) else { return nil }
    }
    // Media comes from the freshly committed source, never from decoded draft
    // bytes. A serialized quote is only the user's text-selection request.
    let quote = fresh.replyQuote.map {
        EngineMessageReplyQuote(text: $0.formattedText.text, offset: $0.selection?.location,
            entities: $0.formattedText.engineEntities(), media: message.media.first)
    }
    return .message(text: formatted.text, attributes: telegramOutgoingTextAttributes(formatted), inlineStickers: [:],
        mediaReference: nil, threadId: fresh.threadID,
        replyToMessageId: EngineMessageReplySubject(messageId: id, quote: quote, todoItemId: nil),
        replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
}

nonisolated func telegramPrepareReplyMessage(postbox: Postbox, accountID: Int64,
    source: TelegramMessageActionSource, formatted: TelegramFormattedText) -> Signal<EnqueueMessage?, NoError> {
    postbox.transaction { telegramReplyEnqueueMessage(transaction: $0, accountID: accountID, source: source, formatted: formatted) }
}

@MainActor func telegramEnqueueReplyMessage(account: Account, approval: TelegramSendApprovalController,
    source: TelegramMessageActionSource, formatted: TelegramFormattedText, message: EnqueueMessage,
    onApproved: @escaping @MainActor () -> Void = {}) -> Signal<[MessageId?]?, NoError> {
    telegramApprovedEnqueue(account: account, approval: approval,
        context: .init(accountID: account.peerId.toInt64(), chatID: source.chatID, threadID: source.threadID,
            submissionRevision: UUID(), messageCount: 1), messages: [message], onApproved: onApproved, specificAdmission:
            telegramReplyAdmission(accountID: account.peerId.toInt64(), source: source, formatted: formatted))
}

nonisolated func telegramReplyAdmission(accountID: Int64, source: TelegramMessageActionSource,
    formatted: TelegramFormattedText) -> (Transaction) -> Bool {
    { transaction in
        telegramReplyEnqueueMessage(transaction: transaction, accountID: accountID, source: source, formatted: formatted) != nil
    }
}
