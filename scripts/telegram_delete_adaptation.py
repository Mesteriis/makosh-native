# SPDX-License-Identifier: GPL-3.0-or-later
"""Exact selected-message delete admission inside the pinned native transaction."""
import hashlib

DELETE = "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessagesInteractively.swift"
SOURCE_SHA256 = 'eba827d5bc733f10e91a4c6ce9d7aab43c5835494afaec2ee0134e0718ec2818'
ADAPTED_SHA256 = 'e53a2387e83d026faf7fed2672659d753b5e40aba4f5c7281e96fe4b2d310c1a'
MARKER = 'func _internal_deleteMessagesInteractively(account: Account,'
API = '''/// Makosh: revalidate the entire frozen selection and delete its exact IDs in one transaction.
/// True means local queue acceptance, not server completion or fsync confirmation.
public func makoshDeleteSelectedMessages(postbox: Postbox, stateManager: AccountStateManager?,
                                        messageIds: [MessageId], type: InteractiveMessagesDeletionType,
                                        transactionAdmission: @escaping (Transaction) -> Bool) -> Signal<Bool, NoError> {
    return postbox.transaction { transaction -> Bool in
        guard !messageIds.isEmpty, messageIds.count <= 100, Set(messageIds).count == messageIds.count,
              transactionAdmission(transaction) else { return false }
        stateManager?.messagesRemovedContext.addIsMessagesDeletedInteractively(ids: messageIds.map { id -> DeletedMessageId in
            let global = id.namespace == Namespaces.Message.Cloud &&
                (id.peerId.namespace == Namespaces.Peer.CloudUser || id.peerId.namespace == Namespaces.Peer.CloudGroup)
            return global ? .global(id.id) : .messageId(id)
        })
        deleteMessagesInteractively(transaction: transaction, stateManager: stateManager, postbox: postbox,
            messageIds: messageIds, type: type, deleteAllInGroup: false, removeIfPossiblyDelivered: true)
        return true
    }
}

'''


def adapt_delete_source(source: str) -> str:
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == ADAPTED_SHA256:
        return source
    if digest != SOURCE_SHA256 or source.count(MARKER) != 1:
        raise ValueError("Unexpected pinned selected-delete input")
    adapted = source.replace(MARKER, API + MARKER)
    if hashlib.sha256(adapted.encode()).hexdigest() != ADAPTED_SHA256:
        raise ValueError("Unexpected adapted selected-delete digest")
    return adapted


def strip_delete_source(source: str) -> str:
    if hashlib.sha256(source.encode()).hexdigest() == SOURCE_SHA256:
        return source
    if hashlib.sha256(source.encode()).hexdigest() != ADAPTED_SHA256 or source.count(API) != 1:
        raise ValueError("Unexpected composed selected-delete input")
    original = source.replace(API, "")
    if hashlib.sha256(original.encode()).hexdigest() != SOURCE_SHA256:
        raise ValueError("Unexpected isolated selected-delete digest")
    return original
