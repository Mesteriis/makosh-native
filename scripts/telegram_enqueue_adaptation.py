# SPDX-License-Identifier: GPL-3.0-or-later
"""Transaction hooks for the pinned engine's ordinary outgoing queue.

Upstream: overtake/Telegram-iOS a24bbe45f9861f736a79916a50898512f751e0dc.
Retains upstream authorship/license; snippets below are patch contexts.
"""
import hashlib

ENQUEUE = "submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift"
SOURCE_SHA256 = "230958d958e40e052c78934a55369fa71fa5b2f7971699a0965a12240124ad04"
ADAPTED_SHA256 = "1eeaf9c208f35c6a0ea0bbffef9213df1008ed29f05cd66f1f3841d165edd35c"

OLD_SIGNATURE = "public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {"
NEW_SIGNATURE = """public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage], transactionAdmission: ((Transaction) -> Bool)? = nil, transactionCommit: ((Transaction, [MessageId?]) -> Void)? = nil) -> Signal<[MessageId?], NoError> {"""
OLD_TRANSACTION = """        return account.postbox.transaction { transaction -> [MessageId?] in
            return enqueueMessages(transaction: transaction, account: account, peerId: peerId, messages: messages)
        }"""
NEW_TRANSACTION = """        return account.postbox.transaction { transaction -> [MessageId?] in
            // Makosh: validate the owned pending draft before admitting any send.
            guard transactionAdmission?(transaction) ?? true else { return [] }
            let ids = enqueueMessages(transaction: transaction, account: account, peerId: peerId, messages: messages)
            // Persist queue admission beside the message, before the UI callback.
            transactionCommit?(transaction, ids)
            return ids
        }"""


def adapt_enqueue_source(source: str) -> str:
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == ADAPTED_SHA256:
        return source
    if digest != SOURCE_SHA256:
        raise ValueError("Unexpected pinned Telegram enqueue source digest")
    if source.count(OLD_SIGNATURE) != 1 or source.count(OLD_TRANSACTION) != 1:
        raise ValueError("Unexpected pinned Telegram enqueue patch context")
    adapted = source.replace(OLD_SIGNATURE, NEW_SIGNATURE).replace(OLD_TRANSACTION, NEW_TRANSACTION)
    if hashlib.sha256(adapted.encode()).hexdigest() != ADAPTED_SHA256:
        raise ValueError("Unexpected adapted Telegram enqueue source digest")
    return adapted
