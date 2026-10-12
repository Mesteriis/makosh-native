import Foundation
import TelegramCore
import Postbox

/// Full native documents are frozen with the payload and checked against the
/// current account cache again after the engine's asynchronous media transforms.
struct TelegramNativeSendPreparation {
    let messages: [EnqueueMessage]
    let context: TelegramSendContext
    let formatted: [TelegramFormattedText?]
    let registries: [TelegramCustomEmojiRegistry?]

    nonisolated func validate(transaction: Transaction) -> Bool {
        guard messages.count == context.messageCount, formatted.count == messages.count,
              registries.count == messages.count else { return false }
        for index in messages.indices {
            guard let value = formatted[index] else { continue }
            guard nativeSendTextValid(value, transaction: transaction) else { return false }
            if let registry = registries[index],
               !telegramCustomEmojiAdmission(formatted: value, registry: registry, transaction: transaction,
                    accountPeerID: PeerId(context.accountID), targetPeerID: PeerId(context.chatID)) { return false }
        }
        return true
    }
}

nonisolated func telegramNativeSendPreparation(transaction: Transaction, context: TelegramSendContext,
    messages: [EnqueueMessage], files: [Int64: TelegramMediaFile], consent: TelegramPaidSendConsent?)
    -> TelegramNativeSendPreparation? {
    guard telegramSendContextIsValid(context), messages.count == context.messageCount,
          files.count <= 1024, files.allSatisfy({ $0.key == $0.value.fileId.id }),
          !messages.contains(where: { $0.attributes.contains { $0 is PaidStarsMessageAttribute } }) else { return nil }
    if let consent {
        guard consent.context == context,
              telegramPaidSendTotal(price: consent.perMessageStars, count: context.messageCount) == consent.totalStars else { return nil }
    }
    var result: [EnqueueMessage] = [], values: [TelegramFormattedText?] = []
    var registries: [TelegramCustomEmojiRegistry?] = [], requested = Set<Int64>()
    for message in messages {
        var prepared = message
        switch message {
        case let .message(text, attributes, _, media, thread, reply, story, grouping, correlation, bubble):
            let entityAttributes = attributes.compactMap { $0 as? TextEntitiesMessageAttribute }
            guard entityAttributes.count <= 1,
                  let value = try? telegramFormattedText(text: text, entities: entityAttributes.first?.entities ?? []),
                  nativeSendTextValid(value, transaction: transaction) else { return nil }
            let ids = Set(value.entities.compactMap { entity -> Int64? in
                if case let .customEmoji(_, fileID) = entity.kind { return fileID }; return nil
            })
            requested.formUnion(ids)
            let registry: TelegramCustomEmojiRegistry?
            if ids.isEmpty { registry = nil }
            else {
                let native = ids.compactMap { files[$0] }
                guard native.count == ids.count,
                      let resolved = try? TelegramCustomEmojiRegistry(accountID: context.accountID, files: native),
                      telegramCustomEmojiAdmission(formatted: value, registry: resolved, transaction: transaction,
                        accountPeerID: PeerId(context.accountID), targetPeerID: PeerId(context.chatID)) else { return nil }
                registry = resolved
            }
            prepared = .message(text: text, attributes: attributes, inlineStickers: registry?.inlineStickers ?? [:],
                mediaReference: media, threadId: thread, replyToMessageId: reply, replyToStoryId: story,
                localGroupingKey: grouping, correlationId: correlation, bubbleUpEmojiOrStickersets: bubble)
            values.append(value); registries.append(registry)
        case .forward:
            values.append(nil); registries.append(nil)
        }
        if let consent {
            prepared = prepared.withUpdatedAttributes { $0 + [PaidStarsMessageAttribute(
                stars: .init(value: consent.perMessageStars, nanos: 0), postponeSending: false)] }
        }
        result.append(prepared)
    }
    guard requested == Set(files.keys) else { return nil }
    return .init(messages: result, context: context, formatted: values, registries: registries)
}

private nonisolated func nativeSendTextValid(_ value: TelegramFormattedText, transaction: Transaction) -> Bool {
    guard value.isEditable, value.text.utf16.count <= 4096 else { return false }
    return value.entities.allSatisfy { entity in
        guard case let .textMention(peerID) = entity.kind else { return true }
        guard let user = transaction.getPeer(PeerId(peerID)) as? TelegramUser else { return false }
        return user.id.namespace == Namespaces.Peer.CloudUser && user.accessHash != nil
    }
}

/// Editing reuses account-bound full custom emoji documents, after a fresh
/// source fingerprint and current edit permission check.
nonisolated func telegramNativeEditInlineStickers(transaction: Transaction, accountID: Int64,
    source: TelegramMessageActionSource, content: TelegramMessageEditContent,
    files: [Int64: TelegramMediaFile]) -> [MediaId: Media]? {
    let id = MessageId(peerId: PeerId(source.peerID), namespace: source.namespace, id: source.messageID)
    guard source.accountID == accountID, let message = transaction.getMessage(id) else { return nil }
    let fresh = TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message,
        limits: currentLimitsConfiguration(transaction: transaction)), accountID: accountID, chatID: source.chatID)
    guard fresh.fingerprint == source.fingerprint,
          telegramMessageActionAllowed(.editFormatted(content.formatted,
            captionAboveMedia: fresh.metadata.hasMedia ? content.captionAboveMedia : nil), source: fresh),
          !content.captionAboveMedia || fresh.metadata.hasMedia else { return nil }
    let context = TelegramSendContext(accountID: accountID, chatID: source.chatID, threadID: fresh.threadID,
        submissionRevision: UUID(), messageCount: 1)
    let outgoing = EnqueueMessage.message(text: content.formatted.text,
        attributes: telegramOutgoingTextAttributes(content.formatted), inlineStickers: [:], mediaReference: nil,
        threadId: fresh.threadID, replyToMessageId: nil, replyToStoryId: nil,
        localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
    guard let prepared = telegramNativeSendPreparation(transaction: transaction, context: context,
        messages: [outgoing], files: files, consent: nil) else { return nil }
    return prepared.registries[0]?.inlineStickers ?? [:]
}
