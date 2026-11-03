import Foundation
import Postbox
import TelegramCore

/// Shared insertion boundary. Destination authorization and payment consumption
/// run in the native queue transaction together with the caller's own receipt.
struct TelegramSendAuthorizationReceipt {
    let context: TelegramSendContext
    let consent: TelegramPaidSendConsent?

    nonisolated func admission(messages: [EnqueueMessage],
        specificAdmission: @escaping (Transaction) -> Bool) -> (Transaction) -> Bool {
        { transaction in
            specificAdmission(transaction) && admit(transaction: transaction, messages: messages)
        }
    }

    nonisolated func admit(transaction: Transaction, messages: [EnqueueMessage]) -> Bool {
        guard consent == nil || consent?.context == context,
              telegramSendAuthorization(transaction: transaction, context: context,
                messages: messages, consentID: consent?.id) else { return false }
        guard let consent else { return true }
        do {
            try telegramPaidSendConsentBegin(transaction: transaction, context: context, consentID: consent.id)
            return true
        } catch { return false }
    }

    nonisolated func acknowledge(transaction: Transaction, messageIDs: [MessageId?]) -> Bool {
        if let consent {
            do {
                try telegramPaidSendConsentConsume(transaction: transaction, context: context,
                    consentID: consent.id, messageIDs: messageIDs)
                return true
            } catch { return false }
        }
        let ids = messageIDs.compactMap { $0 }
        guard ids.count == context.messageCount, Set(ids).count == ids.count else { return false }
        return ids.allSatisfy { id in
            guard id.peerId.toInt64() == context.chatID,
                  id.namespace == Namespaces.Message.Local,
                  let message = transaction.getMessage(id), !message.flags.contains(.Incoming) else { return false }
            return context.threadID == nil || message.threadId == context.threadID
        }
    }
}
