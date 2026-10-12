import Foundation
import Postbox
import TelegramCore

public struct TelegramSendContext: Codable, Equatable, Sendable {
    public let accountID: Int64
    public let chatID: Int64
    public let threadID: Int64?
    public let submissionRevision: UUID
    public let messageCount: Int
    public init(accountID: Int64, chatID: Int64, threadID: Int64?, submissionRevision: UUID, messageCount: Int) {
        self.accountID = accountID; self.chatID = chatID; self.threadID = threadID
        self.submissionRevision = submissionRevision; self.messageCount = messageCount
    }
}

struct TelegramPaidSendConsent: Codable, Equatable, Sendable {
    let id: UUID
    let context: TelegramSendContext
    let perMessageStars: Int64
    let totalStars: Int64
}

public enum TelegramPaidSendConsentError: Error, Equatable, Sendable {
    case unavailable, incompatible, stale
}

/// This special-destination guard supplements normal source/permissions/receipt
/// admission. It neither creates consent nor adds payment attributes.
nonisolated func telegramSendAuthorization(transaction: Transaction, context: TelegramSendContext,
    messages: [EnqueueMessage], consentID: UUID? = nil) -> Bool {
    guard telegramSendContextIsValid(context), messages.count == context.messageCount,
        telegramForumSendAuthorization(transaction: transaction, accountID: context.accountID,
            chatID: context.chatID, threadID: context.threadID, messages: messages),
        case let .success(current) = telegramConversationCapabilities(transaction: transaction,
            accountID: context.accountID, chatID: context.chatID) else { return false }
    if let secret = current.secret {
        guard consentID == nil, secret.state == .active, secret.verification != nil,
            let peer = transaction.getPeer(PeerId(context.chatID)) as? TelegramSecretChat,
            let state = transaction.getPeerChatState(peer.id) as? SecretChatState,
            secretSendKeyAvailable(transaction: transaction, peer: peer, state: state, count: messages.count) else { return false }
        return messages.allSatisfy { message in
            guard case let .message(text, attributes, stickers, media, _, reply, story, grouping, _, bubble) = message else { return false }
            // The base secret boundary supports plain text only. Rich entities,
            // replies and media require their own layer/retention validation.
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 4096
                && attributes.isEmpty && stickers.isEmpty && media == nil && reply == nil && story == nil
                && grouping == nil && bubble.isEmpty
        }
    }
    switch current.messageFee {
    case .unavailable: return false
    case .free:
        return consentID == nil && messages.allSatisfy { message in
            !telegramSendAttributes(message).contains { $0 is PaidStarsMessageAttribute }
        }
    case let .stars(price):
        // All Messages has no immutable paid topic identity. Require a selected
        // topic before requesting approval, even when native reply inference is safe.
        guard !(context.threadID == nil && (transaction.getPeer(PeerId(context.chatID)) as? TelegramChannel)?.flags.contains(.isForum) == true),
            let consentID,
            let record = try? telegramPaidSendConsentRead(transaction: transaction, context: context, consentID: consentID),
            case .pending = record.state,
            record.consent.perMessageStars == price,
            telegramPaidSendTotal(price: price, count: context.messageCount) == record.consent.totalStars else { return false }
        return messages.allSatisfy { telegramPaidSendAttributesMatch(telegramSendAttributes($0), price: price) }
    }
}

nonisolated func telegramSendContextIsValid(_ value: TelegramSendContext) -> Bool {
    let account = PeerId(value.accountID), chat = PeerId(value.chatID)
    let namespaces = [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup,
        Namespaces.Peer.CloudChannel, Namespaces.Peer.SecretChat]
    return account.namespace == Namespaces.Peer.CloudUser && account.id._internalGetInt64Value() > 0
        && chat.id._internalGetInt64Value() > 0 && namespaces.contains(chat.namespace)
        && (chat.namespace != Namespaces.Peer.SecretChat || chat.id._internalGetInt64Value() <= Int64(Int32.max))
        && (1...100).contains(value.messageCount)
        && (value.threadID.map { chat.namespace == Namespaces.Peer.CloudChannel && $0 > 0 && $0 <= Int64(Int32.max) } ?? true)
}

nonisolated func telegramPaidSendTotal(price: Int64, count: Int) -> Int64? {
    guard price > 0, (1...100).contains(count) else { return nil }
    let (total, overflow) = price.multipliedReportingOverflow(by: Int64(count))
    return overflow || total <= 0 ? nil : total
}

nonisolated func telegramSendAttributes(_ value: EnqueueMessage) -> [MessageAttribute] {
    switch value {
    case let .message(_, attributes, _, _, _, _, _, _, _, _), let .forward(_, _, _, attributes, _): return attributes
    }
}

nonisolated func telegramPaidSendAttributesMatch(_ attributes: [MessageAttribute], price: Int64) -> Bool {
    let fees = attributes.compactMap { $0 as? PaidStarsMessageAttribute }
    // Accepted queue IDs must prove this account's authorship. Anonymous/send-as
    // paid sends need a separate reviewed receipt contract.
    return fees.count == 1 && fees[0].stars.value == price && fees[0].stars.nanos == 0
        && !fees[0].postponeSending && !attributes.contains { $0 is SendAsMessageAttribute }
}

private nonisolated func secretSendKeyAvailable(transaction: Transaction, peer: TelegramSecretChat,
    state: SecretChatState, count: Int) -> Bool {
    guard peer.embeddedState == .active, state.embeddedState.peerState == .active, state.role == peer.role,
        state.keyFingerprint != nil, !state.keychain.keys.isEmpty,
        Set(state.keychain.keys.map(\.fingerprint)).count == state.keychain.keys.count,
        state.keychain.keys.allSatisfy({ $0.key.length == 256 && $0.useCount >= 0 && $0.useCount <= Int32.max - Int32(count) }) else { return false }
    switch state.embeddedState {
    case .terminated, .handshake: return false
    case .basicLayer: return state.keychain.indefinitelyValidKey() != nil
    case let .sequenceBasedLayer(sequence):
        let index = transaction.operationLogGetNextEntryLocalIndex(peerId: peer.id, tag: OperationLogTags.SecretOutgoing)
        let (canonical, overflow) = index.subtractingReportingOverflow(sequence.baseOutgoingOperationIndex)
        guard !overflow, canonical >= 0 else { return false }
        let (last, lastOverflow) = canonical.addingReportingOverflow(Int32(count - 1))
        guard !lastOverflow else { return false }
        return state.keychain.latestKey(validForSequenceBasedCanonicalIndex: canonical) != nil
            && state.keychain.latestKey(validForSequenceBasedCanonicalIndex: last) != nil
    }
}
