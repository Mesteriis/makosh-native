# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared local enqueue and transaction hooks for the pinned outgoing queue.

Upstream: overtake/Telegram-iOS a24bbe45f9861f736a79916a50898512f751e0dc.
Retains upstream authorship/license; snippets below are patch contexts.
"""
import hashlib

ENQUEUE = "submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift"
SOURCE_SHA256 = "230958d958e40e052c78934a55369fa71fa5b2f7971699a0965a12240124ad04"
ADAPTED_SHA256 = "05ba874782d908e00b5b1537768aa49ba82c9b4600c720abe0a8520a67fd0649"

OLD_SIGNATURE = "public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {"
NEW_SIGNATURE = """public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage], transactionAdmission: ((Transaction) -> Bool)? = nil, transactionCommit: ((Transaction, [MessageId?]) -> Void)? = nil) -> Signal<[MessageId?], NoError> {"""
OLD_RETURN = """    return signal
    |> mapToSignal { messages -> Signal<[MessageId?], NoError> in
        return account.postbox.transaction { transaction -> [MessageId?] in
            return enqueueMessages(transaction: transaction, account: account, peerId: peerId, messages: messages)
        }
    }
}"""
NEW_RETURN = """    return enqueuePreparedMessages(postbox: account.postbox, accountPeerId: account.peerId,
        isSupportUser: account.isSupportUser, timestamp: { Int32(account.network.context.globalTime()) },
        peerId: peerId, messages: signal, transactionAdmission: transactionAdmission, transactionCommit: transactionCommit)
}

/// Local native queue admission without Account construction or network managers.
/// Unlike the Account entry point, this does not transform outgoing media.
public func enqueueMessagesLocally(postbox: Postbox, accountPeerId: PeerId, isSupportUser: Bool, timestamp: Int32, peerId: PeerId, messages: [EnqueueMessage], transactionAdmission: ((Transaction) -> Bool)? = nil, transactionCommit: ((Transaction, [MessageId?]) -> Void)? = nil) -> Signal<[MessageId?], NoError> {
    return enqueuePreparedMessages(postbox: postbox, accountPeerId: accountPeerId,
        isSupportUser: isSupportUser, timestamp: { timestamp }, peerId: peerId,
        messages: .single(messages.map { (false, $0) }), transactionAdmission: transactionAdmission, transactionCommit: transactionCommit)
}

private func enqueuePreparedMessages(postbox: Postbox, accountPeerId: PeerId, isSupportUser: Bool, timestamp: @escaping () -> Int32, peerId: PeerId, messages: Signal<[(Bool, EnqueueMessage)], NoError>, transactionAdmission: ((Transaction) -> Bool)?, transactionCommit: ((Transaction, [MessageId?]) -> Void)?) -> Signal<[MessageId?], NoError> {
    return messages
    |> mapToSignal { messages -> Signal<[MessageId?], NoError> in
        return postbox.transaction { transaction -> [MessageId?] in
            // Makosh: validate the owned pending draft before admitting any send.
            guard transactionAdmission?(transaction) ?? true else { return [] }
            let ids = enqueueMessages(transaction: transaction, accountPeerId: accountPeerId,
                isSupportUser: isSupportUser, timestamp: timestamp, peerId: peerId, messages: messages)
            // Persist queue admission beside the message, before the UI callback.
            transactionCommit?(transaction, ids)
            return ids
        }
    }
}"""

OLD_CORE_SIGNATURE = "func enqueueMessages(transaction: Transaction, account: Account, peerId: PeerId, messages: [(Bool, EnqueueMessage)], disableAutoremove: Bool = false, transformGroupingKeysWithPeerId: Bool = false) -> [MessageId?] {"
NEW_CORE_SIGNATURE = """func enqueueMessages(transaction: Transaction, account: Account, peerId: PeerId, messages: [(Bool, EnqueueMessage)], disableAutoremove: Bool = false, transformGroupingKeysWithPeerId: Bool = false) -> [MessageId?] {
    return enqueueMessages(transaction: transaction, accountPeerId: account.peerId,
        isSupportUser: account.isSupportUser, timestamp: { Int32(account.network.context.globalTime()) },
        peerId: peerId, messages: messages, disableAutoremove: disableAutoremove,
        transformGroupingKeysWithPeerId: transformGroupingKeysWithPeerId)
}

func enqueueMessages(transaction: Transaction, accountPeerId: PeerId, isSupportUser: Bool, timestamp: () -> Int32, peerId: PeerId, messages: [(Bool, EnqueueMessage)], disableAutoremove: Bool = false, transformGroupingKeysWithPeerId: Bool = false) -> [MessageId?] {"""


# A source message's old charge is never authority to charge its recipient.
# Explicit requested attributes retain their independently confirmed new fee.
SOURCE_FEE_OLD = 'filterMessageAttributesForForwardedMessage(sourceMessage.attributes, forwardedMessageIds: forwardedMessageIds)'
SOURCE_FEE_NEW = 'filterMessageAttributesForForwardedMessage(sourceMessage.attributes.filter { !($0 is PaidStarsMessageAttribute) }, forwardedMessageIds: forwardedMessageIds)'

def adapt_enqueue_source(source: str) -> str:
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == ADAPTED_SHA256:
        return source
    if digest != SOURCE_SHA256:
        raise ValueError("Unexpected pinned Telegram enqueue source digest")
    if any(source.count(context) != 1 for context in (OLD_SIGNATURE, OLD_RETURN, OLD_CORE_SIGNATURE)):
        raise ValueError("Unexpected pinned Telegram enqueue patch context")
    start = source.index(OLD_CORE_SIGNATURE) + len(OLD_CORE_SIGNATURE)
    end = source.index("\n}", start)
    core = source[start:end]
    substitutions = (
        ("account.isSupportUser", "isSupportUser", 1),
        ("account.peerId", "accountPeerId", 8),
        ("Int32(account.network.context.globalTime())", "timestamp()", 1),
    )
    for original, replacement, count in substitutions:
        if core.count(original) != count:
            raise ValueError("Unexpected native enqueue Account scalar context")
        core = core.replace(original, replacement)
    if "account." in core:
        raise ValueError("Unreviewed native enqueue Account dependency")
    adapted = source[:start] + core + source[end:]
    adapted = adapted.replace(OLD_SIGNATURE, NEW_SIGNATURE).replace(OLD_RETURN, NEW_RETURN)
    adapted = adapted.replace(OLD_CORE_SIGNATURE, NEW_CORE_SIGNATURE)
    if adapted.count(SOURCE_FEE_OLD) != 1:
        raise ValueError("Unexpected forwarded source fee context")
    adapted = adapted.replace(SOURCE_FEE_OLD, SOURCE_FEE_NEW)
    if hashlib.sha256(adapted.encode()).hexdigest() != ADAPTED_SHA256:
        raise ValueError("Unexpected adapted Telegram enqueue source digest")
    return adapted
