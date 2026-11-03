import TelegramCore
import Postbox
import SwiftSignalKit

/// Empty and whitespace captions are meaningful; never trim their source text.
func telegramFormattedCaptionCanSend(_ value: TelegramFormattedText, maximumUTF16Count: Int = 1024, allowCustomEmoji: Bool = false) -> Bool {
    guard TelegramUploadCaptionLimit.isValid(maximumUTF16Count),
          value.isEditable, value.text.utf16.count <= maximumUTF16Count else { return false }
    return allowCustomEmoji || !value.entities.contains { if case .customEmoji = $0.kind { return true }; return false }
}

func telegramFormattedCaptionCanSend(_ value: TelegramFormattedText, transaction: Transaction, maximumUTF16Count: Int = 1024, allowCustomEmoji: Bool = false) -> Bool {
    guard telegramFormattedCaptionCanSend(value, maximumUTF16Count: maximumUTF16Count, allowCustomEmoji: allowCustomEmoji) else { return false }
    for entity in value.entities {
        if case let .textMention(peerID) = entity.kind {
            guard let user = transaction.getPeer(PeerId(peerID)) as? TelegramUser,
                  user.id.namespace == Namespaces.Peer.CloudUser, user.accessHash != nil else { return false }
        }
    }
    return true
}

/// Construct the queue callback outside MainActor, including for empty captions.
nonisolated func telegramValidateOutgoingCaption(postbox: Postbox, formatted: TelegramFormattedText, maximumUTF16Count: Int = 1024) -> Signal<Bool, NoError> {
    postbox.transaction { transaction in
        telegramFormattedCaptionCanSend(formatted, transaction: transaction, maximumUTF16Count: maximumUTF16Count)
    }
}
