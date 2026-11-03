import TelegramCore
import Postbox
import SwiftSignalKit

nonisolated func telegramAutomaticDownloadAdmission(postbox: Postbox, source: TelegramAttachmentSource,
    preferences: TelegramAutoDownloadPreferences) -> Signal<Bool, NoError> {
    postbox.transaction { telegramAutomaticDownloadAllowed(transaction: $0, source: source, preferences: preferences) }
}

func telegramAutomaticDownloadAllowed(transaction: Transaction, source: TelegramAttachmentSource,
    preferences: TelegramAutoDownloadPreferences) -> Bool {
    guard source.messageID.namespace == Namespaces.Message.Cloud, source.messageID.id > 0,
          let message = transaction.getMessage(source.messageID), message.flags.contains(.Incoming),
          message.flags.intersection([.Unsent, .Sending, .Failed, .CopyProtected]).isEmpty, !message.containsSecretMedia,
          let peer = transaction.getPeer(message.id.peerId),
          let current = telegramAttachments(message).first(where: { $0.attachment == source.attachment }),
          let resource = current.full?.resource, resource.id == source.full?.resource.id,
          resource is CloudDocumentMediaResource || resource is CloudPhotoSizeMediaResource || resource is CloudFileMediaResource else { return false }
    let category: TelegramDownloadPeer
    if peer is TelegramUser {
        category = transaction.isPeerContact(peerId: peer.id) ? .contacts : .privateChats
    } else if let group = peer as? TelegramGroup {
        guard !group.flags.contains(.copyProtectionEnabled) else { return false }; category = .groups
    } else if let channel = peer as? TelegramChannel {
        guard !channel.flags.contains(.copyProtectionEnabled) else { return false }
        if case .broadcast = channel.info { category = .channels } else { category = .groups }
    } else { return false }
    return preferences.allows(current.attachment, peer: category)
}
