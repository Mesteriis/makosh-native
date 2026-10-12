import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

public struct TelegramPaidSendQueueID: Codable, Equatable, Hashable, Sendable {
    public let peerID: Int64
    public let namespace: Int32
    public let messageID: Int32
}

struct TelegramPaidSendConsentRecord: Codable, Equatable, Sendable {
    enum State: Codable, Equatable, Sendable {
        case pending
        case submissionStarted
        case accepted([TelegramPaidSendQueueID])
    }
    let schemaVersion: Int
    let consent: TelegramPaidSendConsent
    let state: State
}

public enum TelegramPaidSendRecovery: Equatable, Sendable {
    case pending
    case submissionStarted
    case accepted([TelegramPaidSendQueueID])
}

public nonisolated func telegramPaidSendConsentRecovery(postbox: Postbox, context: TelegramSendContext,
    consentID: UUID) -> Signal<Result<TelegramPaidSendRecovery?, TelegramPaidSendConsentError>, NoError> {
    postbox.transaction { transaction -> Result<TelegramPaidSendRecovery?, TelegramPaidSendConsentError> in
        do {
            guard let record = try telegramPaidSendConsentRead(transaction: transaction, context: context, consentID: consentID) else {
                return .success(nil)
            }
            switch record.state {
            case .pending: return .success(.pending)
            case .submissionStarted: return .success(.submissionStarted)
            case let .accepted(ids): return .success(.accepted(ids))
            }
        } catch let error as TelegramPaidSendConsentError { return .failure(error) }
        catch { return .failure(.incompatible) }
    } |> deliverOnMainQueue
}

private let paidSendMarker = Data("Makosh.PaidSend.Consent.v1\n".utf8)
private let paidSendMaximumBytes = 32 * 1024

nonisolated func telegramPaidSendConsentKey(context: TelegramSendContext, consentID: UUID) -> ValueBoxKey {
    let namespace = Data("Makosh.PaidSend.Consent.Preference.v1\0".utf8)
    let key = ValueBoxKey(length: namespace.count + 32)
    key.setData(0, value: namespace)
    key.setInt64(namespace.count, value: context.accountID)
    key.setInt64(namespace.count + 8, value: context.chatID)
    var uuid = consentID.uuid
    withUnsafeBytes(of: &uuid) { key.setData(namespace.count + 16, value: Data($0)) }
    return key
}

nonisolated func telegramPaidSendConsentRead(transaction: Transaction, context: TelegramSendContext,
    consentID: UUID) throws -> TelegramPaidSendConsentRecord? {
    guard let entry = transaction.getPreferencesEntry(key: telegramPaidSendConsentKey(context: context, consentID: consentID)) else { return nil }
    guard entry.data.count <= paidSendMaximumBytes, entry.data.starts(with: paidSendMarker),
        let record = try? JSONDecoder().decode(TelegramPaidSendConsentRecord.self, from: entry.data.dropFirst(paidSendMarker.count)),
        record.schemaVersion == 1, record.consent.id == consentID, record.consent.context == context,
        telegramSendContextIsValid(context),
        telegramPaidSendTotal(price: record.consent.perMessageStars, count: context.messageCount) == record.consent.totalStars else {
        throw TelegramPaidSendConsentError.incompatible
    }
    if case let .accepted(ids) = record.state {
        guard paidSendIDsValid(ids, context: context) else { throw TelegramPaidSendConsentError.incompatible }
    }
    return record
}

/// Invoke only from the application's explicit, displayed Pay confirmation.
/// The fresh current fee and immutable submission context are checked again.
nonisolated func telegramPaidSendConsentCreate(transaction: Transaction, context: TelegramSendContext,
    perMessageStars: Int64, consentID: UUID) throws -> TelegramPaidSendConsent {
    guard telegramSendContextIsValid(context), paidSendDestinationCurrent(transaction: transaction, context: context),
        let total = telegramPaidSendTotal(price: perMessageStars, count: context.messageCount),
        case let .success(current) = telegramConversationCapabilities(transaction: transaction,
            accountID: context.accountID, chatID: context.chatID), current.secret == nil,
        current.messageFee == .stars(perMessageStars) else { throw TelegramPaidSendConsentError.unavailable }
    let consent = TelegramPaidSendConsent(id: consentID, context: context,
        perMessageStars: perMessageStars, totalStars: total)
    if let existing = try telegramPaidSendConsentRead(transaction: transaction, context: context, consentID: consentID) {
        guard existing.consent == consent, case .pending = existing.state else { throw TelegramPaidSendConsentError.stale }
        return existing.consent
    }
    try paidSendWrite(transaction: transaction, record: .init(schemaVersion: 1, consent: consent, state: .pending))
    return consent
}

/// Pure admission must succeed first. Mark started before insertion in that same
/// transaction so a partial native result can never leave reusable approval.
nonisolated func telegramPaidSendConsentBegin(transaction: Transaction, context: TelegramSendContext,
    consentID: UUID) throws {
    guard paidSendDestinationCurrent(transaction: transaction, context: context),
        let record = try telegramPaidSendConsentRead(transaction: transaction, context: context, consentID: consentID),
        case .pending = record.state,
        case let .success(current) = telegramConversationCapabilities(transaction: transaction,
            accountID: context.accountID, chatID: context.chatID), current.secret == nil,
        current.messageFee == .stars(record.consent.perMessageStars) else { throw TelegramPaidSendConsentError.stale }
    try paidSendWrite(transaction: transaction, record: .init(schemaVersion: 1,
        consent: record.consent, state: .submissionStarted))
}

/// Same native insertion transaction, after complete local IDs are available.
nonisolated func telegramPaidSendConsentConsume(transaction: Transaction, context: TelegramSendContext,
    consentID: UUID, messageIDs: [MessageId?]) throws {
    guard let record = try telegramPaidSendConsentRead(transaction: transaction, context: context, consentID: consentID),
        case .submissionStarted = record.state, messageIDs.count == context.messageCount,
        messageIDs.allSatisfy({ $0 != nil }) else { throw TelegramPaidSendConsentError.stale }
    let ids = messageIDs.compactMap { $0 }.map {
        TelegramPaidSendQueueID(peerID: $0.peerId.toInt64(), namespace: $0.namespace, messageID: $0.id)
    }
    guard paidSendIDsValid(ids, context: context) else { throw TelegramPaidSendConsentError.incompatible }
    for id in ids {
        guard let queued = transaction.getMessage(MessageId(peerId: PeerId(id.peerID), namespace: id.namespace, id: id.messageID)),
            !queued.flags.contains(.Incoming), queued.author?.id.toInt64() == context.accountID,
            queued.threadId == context.threadID,
            telegramPaidSendAttributesMatch(queued.attributes, price: record.consent.perMessageStars) else {
            throw TelegramPaidSendConsentError.incompatible
        }
    }
    try paidSendWrite(transaction: transaction, record: .init(schemaVersion: 1,
        consent: record.consent, state: .accepted(ids)))
}

private nonisolated func paidSendDestinationCurrent(transaction: Transaction,
    context: TelegramSendContext) -> Bool {
    if let channel = transaction.getPeer(PeerId(context.chatID)) as? TelegramChannel,
        channel.flags.contains(.isForum) {
        guard let thread = context.threadID else { return false }
        return telegramForumSendTopic(transaction: transaction, chatID: context.chatID, threadID: thread) != nil
    }
    return context.threadID == nil
}

private nonisolated func paidSendIDsValid(_ ids: [TelegramPaidSendQueueID], context: TelegramSendContext) -> Bool {
    ids.count == context.messageCount && !ids.isEmpty && Set(ids).count == ids.count
        && ids.allSatisfy { $0.peerID == context.chatID && $0.namespace == Namespaces.Message.Local }
}

private nonisolated func paidSendWrite(transaction: Transaction, record: TelegramPaidSendConsentRecord) throws {
    let data: Data
    do {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        data = try encoder.encode(record)
    } catch { throw TelegramPaidSendConsentError.incompatible }
    guard data.count <= paidSendMaximumBytes - paidSendMarker.count else { throw TelegramPaidSendConsentError.incompatible }
    transaction.setPreferencesEntry(key: telegramPaidSendConsentKey(context: record.consent.context, consentID: record.consent.id),
        value: .init(data: paidSendMarker + data))
}
