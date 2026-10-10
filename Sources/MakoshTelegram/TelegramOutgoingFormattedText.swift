import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Admission for text-only outgoing messages. Inline custom emoji needs a
/// separately resolved media registry; retaining its DTO is not send authority.
func telegramFormattedTextCanSend(_ value: TelegramFormattedText) -> Bool {
    guard value.isEditable, value.text.utf16.count <= 4096,
          !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return !value.entities.contains { if case .customEmoji = $0.kind { return true }; return false }
}

func telegramFormattedTextCanSend(_ value: TelegramFormattedText, transaction: Transaction) -> Bool {
    guard telegramFormattedTextCanSend(value) else { return false }
    for entity in value.entities {
        if case let .textMention(peerID) = entity.kind {
            guard let user = transaction.getPeer(PeerId(peerID)) as? TelegramUser,
                  user.id.namespace == Namespaces.Peer.CloudUser, user.accessHash != nil else { return false }
        }
    }
    return true
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

nonisolated func telegramEnqueueOutgoingText(account: Account, chatID: Int64, formatted: TelegramFormattedText) -> Signal<[MessageId?]?, NoError> {
    telegramValidateOutgoingText(postbox: account.postbox, formatted: formatted)
    |> mapToSignal { valid -> Signal<[MessageId?]?, NoError> in
        guard valid else { return .single(nil) }
        let message = EnqueueMessage.message(text: formatted.text,
            attributes: telegramOutgoingTextAttributes(formatted), inlineStickers: [:], mediaReference: nil,
            threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil,
            correlationId: nil, bubbleUpEmojiOrStickersets: [])
        return enqueueMessages(account: account, peerId: PeerId(chatID), messages: [message]) |> map { Optional($0) }
    }
}
