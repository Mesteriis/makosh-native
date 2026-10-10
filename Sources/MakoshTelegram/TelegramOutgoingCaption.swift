import TelegramCore
import Postbox
import SwiftSignalKit

/// Empty and whitespace captions are meaningful; never trim their source text.
func telegramFormattedCaptionCanSend(_ value: TelegramFormattedText) -> Bool {
    guard value.isEditable, value.text.utf16.count <= 1024 else { return false }
    return !value.entities.contains { if case .customEmoji = $0.kind { return true }; return false }
}

func telegramFormattedCaptionCanSend(_ value: TelegramFormattedText, transaction: Transaction) -> Bool {
    guard telegramFormattedCaptionCanSend(value) else { return false }
    for entity in value.entities {
        if case let .textMention(peerID) = entity.kind {
            guard let user = transaction.getPeer(PeerId(peerID)) as? TelegramUser,
                  user.id.namespace == Namespaces.Peer.CloudUser, user.accessHash != nil else { return false }
        }
    }
    return true
}

/// Construct the queue callback outside MainActor, including for empty captions.
nonisolated func telegramValidateOutgoingCaption(postbox: Postbox, formatted: TelegramFormattedText) -> Signal<Bool, NoError> {
    postbox.transaction { transaction in
        telegramFormattedCaptionCanSend(formatted, transaction: transaction)
    }
}
