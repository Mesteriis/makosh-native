import Foundation
import Postbox
import TelegramCore

/// Native encrypted payloads support fewer fields than cloud messages. Admit
/// only representations that the negotiated encoder will preserve.
nonisolated func telegramSecretSendAuthorization(transaction: Transaction, peer: TelegramSecretChat, state: SecretChatState,
    accountID: Int64, message: EnqueueMessage) -> Bool {
    guard let layer = telegramSecretLayer(state),
          case let .message(text, attributes, stickers, media, thread, reply, story, grouping, _, bubble) = message,
          thread == nil, story == nil, bubble.isEmpty, grouping == nil || (layer >= 73 && media != nil),
          attributes.allSatisfy({ $0 is TextEntitiesMessageAttribute }),
          attributes.compactMap({ $0 as? TextEntitiesMessageAttribute }).count <= 1 else { return false }
    let entities = attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first?.entities ?? []
    guard let formatted = try? telegramFormattedText(text: text, entities: entities), formatted.isEditable,
          text.utf16.count <= (media == nil ? 4096 : 1024),
          media != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          makoshSecretEntitiesAreLossless(entities, layer: layer) else { return false }
    let emojiIDs = Set(formatted.entities.compactMap { entity -> Int64? in
        if case let .customEmoji(_, id) = entity.kind { return id }; return nil
    })
    let emojiFiles = stickers.values.compactMap { $0 as? TelegramMediaFile }
    guard emojiFiles.count == stickers.count, Set(stickers.keys) == Set(emojiFiles.map(\.fileId)),
          Set(emojiFiles.map { $0.fileId.id }) == emojiIDs else { return false }
    if !emojiIDs.isEmpty {
        guard let registry = try? TelegramCustomEmojiRegistry(accountID: accountID, files: emojiFiles),
              telegramCustomEmojiAdmission(formatted: formatted, registry: registry, transaction: transaction,
                accountPeerID: PeerId(accountID), targetPeerID: peer.id) else { return false }
    }
    if let reply {
        guard layer >= 46, reply.messageId.peerId == peer.id, reply.quote == nil, reply.todoItemId == nil,
              let source = transaction.getMessage(reply.messageId), telegramSecretReplySource(source) else { return false }
    }
    guard let media else { return true }
    guard layer >= 46, case let .standalone(value) = media else { return false }
    if let photo = value as? TelegramMediaImage {
        guard photo.flags.isEmpty, photo.partialReference == nil, photo.reference == nil,
              !photo.representations.isEmpty, photo.representations.count <= 64 else { return false }
        return photo.representations.allSatisfy { representation in
            guard representation.dimensions.width > 0, representation.dimensions.height > 0,
                  let resource = representation.resource as? LocalFileMediaResource, let size = resource.size else { return false }
            return size > 0 && size <= Int64(Int32.max)
        }
    }
    guard let file = value as? TelegramMediaFile, file.videoCover == nil, file.partialReference == nil,
          file.alternativeRepresentations.isEmpty, let resource = file.resource as? LocalFileMediaResource,
          let size = resource.size, size > 0, file.size.map({ $0 == size }) ?? true,
          layer >= 144 || size <= Int64(Int32.max), file.mimeType.utf8.count <= 255, !file.mimeType.isEmpty,
          file.attributes.count <= 32 else { return false }
    return file.attributes.allSatisfy { attribute in
        switch attribute {
        case let .FileName(name): return !name.isEmpty && name.utf16.count <= 1024 && !name.contains("\0")
        case let .ImageSize(size): return size.width > 0 && size.height > 0
        case .Animated, .hintFileIsLarge, .hintIsValidated: return true
        case let .Video(duration, size, flags, _, _, _):
            return duration.isFinite && duration >= 0 && duration < Double(Int32.max) && size.width > 0 && size.height > 0
                && (!flags.contains(.instantRoundVideo) || layer >= 73)
        case let .Audio(_, duration, _, _, waveform):
            return duration >= 0 && duration <= Int(Int32.max) && (waveform?.count ?? 0) <= 1024
        case .Sticker, .HasLinkedStickers, .NoPremium, .CustomEmoji: return false
        }
    }
}
nonisolated func telegramSecretReplySource(_ message: Message) -> Bool {
    telegramSecretPeerID(message.id.peerId.toInt64()) != nil && message.id.id > 0
        && [Namespaces.Message.SecretIncoming, Namespaces.Message.Local].contains(message.id.namespace)
        && message.globallyUniqueId.map({ $0 != 0 }) == true
        && !message.flags.contains(.Unsent) && !message.flags.contains(.Sending) && !message.flags.contains(.Failed)
}
