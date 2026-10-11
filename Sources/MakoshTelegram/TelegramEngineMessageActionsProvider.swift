import Foundation
import CryptoKit
import TelegramCore
import Postbox
import SwiftSignalKit

/// Version token includes encoded attributes/media, not just displayed text or ID.
public func telegramMessageActionMetadata(_ message: Message, now: Date = Date(), limits: LimitsConfiguration? = nil) -> TelegramMessageActionMetadata {
    let encoder = PostboxEncoder()
    encoder.encodeString(message.text, forKey: "text")
    encoder.encodeInt32(message.timestamp, forKey: "date")
    encoder.encodeInt64(Int64(message.stableVersion), forKey: "version")
    encoder.encodeInt64(Int64(message.flags.rawValue), forKey: "flags")
    encoder.encodeInt64(message.author?.id.toInt64() ?? 0, forKey: "author")
    encoder.encodeObjectArrayWithEncoder(message.attributes, forKey: "attributes", encoder: { $0.encode($1) })
    encoder.encodeObjectArrayWithEncoder(message.media, forKey: "media", encoder: { $0.encode($1) })
    if let thread = message.threadId { encoder.encodeInt64(thread, forKey: "thread") }
    else { encoder.encodeNil(forKey: "thread") }
    let fingerprint = SHA256.hash(data: encoder.makeData()).map { String(format: "%02x", $0) }.joined()
    let peer = message.peers[message.id.peerId]
    let channel = peer as? TelegramChannel
    let group = peer as? TelegramGroup
    let supportedPeer = peer is TelegramUser || group != nil || channel != nil
    let stable = message.id.namespace == Namespaces.Message.Cloud && message.id.id > 0 &&
        !message.flags.contains(.Unsent) && !message.flags.contains(.Sending) && !message.flags.contains(.Failed)
    let ordinaryMedia = message.media.allSatisfy { $0 is TelegramMediaImage || $0 is TelegramMediaFile || $0 is TelegramMediaWebpage }
    let ordinary = supportedPeer && stable
    let forwardable = !message.media.contains { $0 is TelegramMediaAction || $0 is TelegramMediaPaidContent }
    let protected = message.flags.contains(.CopyProtected) || channel?.flags.contains(.copyProtectionEnabled) == true || group?.flags.contains(.copyProtectionEnabled) == true
    let entities = message.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.flatMap(\.entities)
    let formatted = try? telegramFormattedText(text: message.text, entities: entities)
    let editAdmin = channel?.hasPermission(.editAllMessages) == true
    let groupDeleteAdmin: Bool
    if let group {
        switch group.role {
        case .creator: groupDeleteAdmin = true
        case let .admin(rights, _): groupDeleteAdmin = rights.rights.contains(.canDeleteMessages)
        case .member: groupDeleteAdmin = false
        }
    } else { groupDeleteAdmin = false }
    let deleteAdmin = channel?.hasPermission(.deleteAllMessages) == true || groupDeleteAdmin
    let outgoing = !message.flags.contains(.Incoming)
    let outgoingChannel = outgoing && channel?.hasPermission(.sendText) == true
    // Without configuration this is a UI candidate. Dispatch always revalidates
    // against the selected account's freshly stored server configuration.
    let age = now.timeIntervalSince1970 - Double(message.timestamp)
    let incomingPrivate = peer is TelegramUser && !outgoing && (limits.map {
        $0.canRemoveIncomingMessagesInPrivateChats && age >= 0 &&
        ($0.maxMessageRevokeIntervalInPrivateChats == LimitsConfiguration.timeIntervalForever ||
         age <= Double($0.maxMessageRevokeIntervalInPrivateChats))
    } ?? true)
    return TelegramMessageActionMetadata(peerID: message.id.peerId.toInt64(), namespace: message.id.namespace,
        messageID: message.id.id, fingerprint: fingerprint, text: message.text, authorID: message.author?.id.toInt64(),
        canReply: ordinary && (channel?.hasPermission(.sendText) ?? true) && !(group?.hasBannedPermission(.banSendText) ?? false),
        canEdit: ordinary && ordinaryMedia && formatted?.isEditable == true && message.forwardInfo == nil && (outgoing || editAdmin),
        canForward: ordinary && forwardable && !protected,
        canDeleteLocally: ordinary && channel == nil,
        canDeleteForEveryone: ordinary && (outgoing || deleteAdmin || incomingPrivate),
        canEditAsAdmin: editAdmin, canDeleteAsAdmin: deleteAdmin, canDeleteIncomingPrivate: incomingPrivate,
        migrationChatID: group?.migrationReference?.peerId.toInt64(),
        allowsEmptyEdit: message.media.contains { $0 is TelegramMediaImage || $0 is TelegramMediaFile },
        editLimit: message.media.contains { $0 is TelegramMediaImage || $0 is TelegramMediaFile } ? 1024 : 4096,
        hasMedia: !message.media.isEmpty, captionAboveMedia: message.attributes.contains { $0 is InvertMediaMessageAttribute },
        threadID: message.threadId, formattedText: formatted,
        canEditOutgoingChannel: outgoingChannel, canDeleteOutgoingChannel: outgoingChannel, canCopy: supportedPeer && !protected)
}

public func telegramMessageActionSource(_ message: Message, accountID: Int64, chatID: Int64, now: Date = Date()) -> TelegramMessageActionSource {
    TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message, now: now), accountID: accountID, chatID: chatID)
}

// Postbox executes this closure on its own queue, outside MainActor isolation.
func validateTelegramMessageAction(postbox: Postbox, accountID: Int64, action: TelegramMessageAction,
                                   source: TelegramMessageActionSource) -> Signal<Bool, NoError> {
    validatedTelegramActionSource(postbox: postbox, accountID: accountID, source: source, action: action)
    |> map { $0 != nil }
}

func validatedTelegramEditContent(postbox: Postbox, accountID: Int64, action: TelegramMessageAction,
                                  source: TelegramMessageActionSource) -> Signal<TelegramMessageEditContent?, NoError> {
    validatedTelegramActionSource(postbox: postbox, accountID: accountID, source: source, action: action)
    |> map { fresh in fresh.flatMap { TelegramMessageEditContent(action: action, source: $0) } }
}

func validateTelegramReplySource(postbox: Postbox, accountID: Int64,
                                source: TelegramMessageActionSource) -> Signal<TelegramMessageActionSource?, NoError> {
    validatedTelegramActionSource(postbox: postbox, accountID: accountID, source: source, action: nil)
}

private func validatedTelegramActionSource(postbox: Postbox, accountID: Int64,
    source: TelegramMessageActionSource, action: TelegramMessageAction?) -> Signal<TelegramMessageActionSource?, NoError> {
    let id = MessageId(peerId: PeerId(source.peerID), namespace: source.namespace, id: source.messageID)
    return postbox.transaction { transaction -> TelegramMessageActionSource? in
        guard source.accountID == accountID, let message = transaction.getMessage(id) else { return nil }
        let fresh = TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message,
            limits: currentLimitsConfiguration(transaction: transaction)), accountID: accountID, chatID: source.chatID)
        guard fresh.fingerprint == source.fingerprint else { return nil }
        if let action {
            guard telegramMessageActionAllowed(action, source: fresh) else { return nil }
        } else {
            guard fresh.canReply, fresh.chatID == fresh.peerID || fresh.metadata.migrationChatID == fresh.chatID else { return nil }
        }
        if case let .replyFormatted(formatted)? = action {
            guard telegramFormattedTextCanSend(formatted, transaction: transaction) else { return nil }
        }
        if case let .editFormatted(formatted, _)? = action {
            for entity in formatted.entities {
                if case let .textMention(peerID) = entity.kind {
                    // apiInputUser is internal upstream; otherwise it drops this entity.
                    guard let user = transaction.getPeer(PeerId(peerID)) as? TelegramUser,
                          user.accessHash != nil else { return nil }
                }
            }
        }
        if source.chatID != source.peerID {
            guard let group = transaction.getPeer(id.peerId) as? TelegramGroup,
                  group.migrationReference?.peerId == PeerId(source.chatID) else { return nil }
        }
        if case let .forward(destination)? = action {
            guard let peer = transaction.getPeer(PeerId(destination)) else { return nil }
            if let channel = peer as? TelegramChannel {
                guard channel.hasPermission(.sendSomething) else { return nil }
            } else if let group = peer as? TelegramGroup {
                guard group.hasPermission(.sendSomething) else { return nil }
            } else if !(peer is TelegramUser) { return nil }
        }
        return fresh
    }
}

private func reconcileEditedMessage(account: Account, id: MessageId, content: TelegramMessageEditContent) -> Signal<Bool, NoError> {
    account.postbox.transaction { transaction in
        guard let message = transaction.getMessage(id) else { return false }
        return content.matches(message)
    }
}

@MainActor final class TelegramEngineMessageActionsProvider: TelegramMessageActionsProvider {
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func start(action: TelegramMessageAction, source: TelegramMessageActionSource,
               receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease {
        let lease = EngineMessageActionsLease(receive: receive)
        guard source.accountID == accountID, telegramMessageActionAllowed(action, source: source) else {
            receive(.rejected); return lease
        }
        let id = MessageId(peerId: PeerId(source.peerID), namespace: source.namespace, id: source.messageID)
        let validation: Signal<(valid: Bool, editContent: TelegramMessageEditContent?), NoError>
        switch action {
        case .edit, .editFormatted:
            validation = validatedTelegramEditContent(postbox: account.postbox, accountID: accountID, action: action, source: source)
                |> map { (valid: $0 != nil, editContent: $0) }
        default:
            validation = validateTelegramMessageAction(postbox: account.postbox, accountID: accountID, action: action, source: source)
                |> map { (valid: $0, editContent: nil) }
        }
        lease.validation.set((validation |> deliverOnMainQueue).start(next: { [weak lease, account] result in
            guard let lease, !lease.stopped else { return }
            guard result.valid else { lease.emit(.rejected); return }
            lease.receive(.committing)
            guard !lease.stopped else { return }
            switch action {
            case .reply, .replyFormatted:
                let formatted: TelegramFormattedText
                switch action {
                case let .reply(text):
                    guard let value = try? TelegramFormattedText(text: text) else { lease.emit(.rejected); return }
                    formatted = value
                case let .replyFormatted(value): formatted = value
                default: return
                }
                let message = EnqueueMessage.message(text: formatted.text, attributes: telegramOutgoingTextAttributes(formatted), inlineStickers: [:], mediaReference: nil,
                    threadId: source.threadID, replyToMessageId: EngineMessageReplySubject(messageId: id, quote: nil, todoItemId: nil),
                    replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
                lease.operation.set((enqueueMessages(account: account, peerId: PeerId(source.chatID), messages: [message])
                    |> deliverOnMainQueue).start(next: { [weak lease] ids in
                        lease?.emit(ids.first.flatMap { $0 } == nil ? .uncertain : .queued)
                    }))
            case let .forward(destination):
                lease.operation.set((enqueueMessages(account: account, peerId: PeerId(destination), messages: [
                    .forward(source: id, threadId: nil, grouping: .none, attributes: [], correlationId: nil)
                ]) |> deliverOnMainQueue).start(next: { [weak lease] ids in
                    lease?.emit(ids.first.flatMap { $0 } == nil ? .uncertain : .queued)
                }))
            case .edit, .editFormatted:
                guard let content = result.editContent else { lease.emit(.rejected); return }
                // Empty plain messages are invalid; an empty supported media caption is allowed.
                lease.operation.set((TelegramEngine(account: account).messages.requestEditMessage(messageId: id, text: content.formatted.text,
                    media: .keep, entities: TextEntitiesMessageAttribute(entities: content.formatted.engineEntities()), inlineStickers: [:],
                    invertMediaAttribute: content.invertMediaAttribute)
                    |> deliverOnMainQueue).start(next: { [weak lease] result in
                        if case let .done(changed) = result {
                            guard let lease, !lease.stopped else { return }
                            if changed { lease.emit(.applied) }
                            else {
                                // false also covers missing input peer/message, not only NOT_MODIFIED.
                                lease.reconciliation.set((reconcileEditedMessage(account: account, id: id, content: content)
                                    |> deliverOnMainQueue).start(next: { [weak lease] matches in
                                        lease?.emit(matches ? .applied : .uncertain)
                                    }))
                            }
                        }
                    }, error: { [weak lease] error in
                        switch error {
                        case .restricted, .textTooLong, .invalidGrouping: lease?.emit(.rejected)
                        case .generic: lease?.emit(.uncertain)
                        }
                    }))
            case let .delete(everyone):
                lease.operation.set((TelegramEngine(account: account).messages.deleteMessagesInteractively(messageIds: [id],
                    type: everyone ? .forEveryone : .forLocalPeer, deleteAllInGroup: false)
                    |> deliverOnMainQueue).start(completed: { [weak lease] in lease?.emit(.queued) }))
            }
        }))
        return lease
    }
}

@MainActor private final class EngineMessageActionsLease: TelegramMessageActionsLease {
    let validation = MetaDisposable(), operation = MetaDisposable(), reconciliation = MetaDisposable()
    let receive: @MainActor (TelegramMessageActionEvent) -> Void
    private(set) var stopped = false
    init(receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) { self.receive = receive }
    func emit(_ event: TelegramMessageActionEvent) { guard !stopped else { return }; receive(event); cancel() }
    func cancel() { guard !stopped else { return }; stopped = true; validation.dispose(); operation.dispose(); reconciliation.dispose() }
    isolated deinit { validation.dispose(); operation.dispose(); reconciliation.dispose() }
}
