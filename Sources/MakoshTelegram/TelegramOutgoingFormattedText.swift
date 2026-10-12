import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Admission for text-only outgoing messages. Inline custom emoji needs a
/// separately resolved media registry; retaining its DTO is not send authority.
/// Structural editor/preparation validation. A custom emoji remains unresolved
/// until the shared native queue verifies its full account-bound document.
func telegramFormattedTextCanPrepare(_ value: TelegramFormattedText) -> Bool {
    value.isEditable && value.text.utf16.count <= 4096 &&
        !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
func telegramFormattedTextCanPrepare(_ value: TelegramFormattedText, transaction: Transaction) -> Bool {
    guard telegramFormattedTextCanPrepare(value) else { return false }
    for entity in value.entities {
        if case let .textMention(peerID) = entity.kind {
            guard let user = transaction.getPeer(PeerId(peerID)) as? TelegramUser,
                  user.id.namespace == Namespaces.Peer.CloudUser, user.accessHash != nil else { return false }
        }
    }
    return true
}
func telegramFormattedTextCanSend(_ value: TelegramFormattedText) -> Bool {
    telegramFormattedTextCanPrepare(value) && !value.entities.contains {
        if case .customEmoji = $0.kind { return true }; return false
    }
}
func telegramFormattedTextCanSend(_ value: TelegramFormattedText, transaction: Transaction) -> Bool {
    telegramFormattedTextCanSend(value) && telegramFormattedTextCanPrepare(value, transaction: transaction)
}

/// Call only after admission; all original UTF16 ranges and native kinds survive.
func telegramOutgoingTextAttributes(_ value: TelegramFormattedText) -> [MessageAttribute] {
    value.entities.isEmpty ? [] : [TextEntitiesMessageAttribute(entities: value.engineEntities())]
}

// Construct queue-executed closures outside MainActor callers. Postbox's
// transaction callback is non-Sendable and must not inherit UI actor isolation.
nonisolated func telegramValidateOutgoingText(postbox: Postbox, formatted: TelegramFormattedText) -> Signal<Bool, NoError> {
    postbox.transaction { transaction in
        telegramFormattedTextCanSend(formatted, transaction: transaction)
    }
}

@MainActor func telegramEnqueueOutgoingText(account: Account, approval: TelegramSendApprovalController,
    chatID: Int64, threadID: Int64?, revision: UUID, formatted: TelegramFormattedText) -> Signal<[MessageId?]?, NoError> {
    guard telegramFormattedTextCanPrepare(formatted) else { return .single([]) }
    let message = EnqueueMessage.message(text: formatted.text,
        attributes: telegramOutgoingTextAttributes(formatted), inlineStickers: [:], mediaReference: nil,
        threadId: threadID, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil,
        correlationId: nil, bubbleUpEmojiOrStickersets: [])
    return telegramApprovedEnqueue(account: account, approval: approval,
        context: .init(accountID: account.peerId.toInt64(), chatID: chatID, threadID: threadID,
            submissionRevision: revision, messageCount: 1), messages: [message])
}
