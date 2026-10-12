import Foundation
import Postbox
import TelegramCore

// The native input and this basis are committed with the local composer in one
// Postbox transaction. A changed native basis is never overwritten by a late UI
// save or send acknowledgement. No Account/network is needed by this boundary.
private struct TelegramServerDraftBasis: Codable {
    let schemaVersion: Int
    let accountID: Int64
    let chatID: Int64
    let threadID: Int64?
    let revision: UUID
    let native: SynchronizeableChatInputState?
}

private let serverDraftMarker = Data("Makosh.ServerDraft.Basis.v1\n".utf8)
nonisolated func telegramServerDraftBasisKey(accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> ValueBoxKey {
    let namespace = Data("Makosh.ServerDraft.Basis.Preference.v1\0".utf8)
    let key = ValueBoxKey(length: namespace.count + (threadID == nil ? 16 : 24))
    key.setData(0, value: namespace)
    key.setInt64(namespace.count, value: accountID)
    key.setInt64(namespace.count + 8, value: chatID)
    if let threadID { key.setInt64(namespace.count + 16, value: threadID) }
    return key
}
private nonisolated func cloudDraftPeer(_ id: Int64) -> Bool {
    let namespace = PeerId(id).namespace
    return namespace == Namespaces.Peer.CloudUser || namespace == Namespaces.Peer.CloudGroup || namespace == Namespaces.Peer.CloudChannel
}
private nonisolated func nativeDraft(transaction: Transaction, chatID: Int64, threadID: Int64?) throws -> SynchronizeableChatInputState? {
    let state = threadID.flatMap { transaction.getPeerChatThreadInterfaceState(PeerId(chatID), threadId: $0) }
        ?? (threadID == nil ? transaction.getPeerChatInterfaceState(PeerId(chatID)) : nil)
    guard let state, state.data != nil else { return nil }
    guard let data = state.data, data.count <= 512 * 1024,
          let decoded = _internal_decodeStoredChatInterfaceState(state: state) else {
        throw TelegramComposerDraftPersistenceError.incompatibleData
    }
    return decoded.synchronizeableInputState
}
private nonisolated func basis(transaction: Transaction, accountID: Int64, chatID: Int64, threadID: Int64?) throws -> TelegramServerDraftBasis? {
    guard let entry = transaction.getPreferencesEntry(key: telegramServerDraftBasisKey(accountID: accountID, chatID: chatID, threadID: threadID)) else { return nil }
    guard entry.data.count <= 512 * 1024, entry.data.starts(with: serverDraftMarker),
          let value = try? JSONDecoder().decode(TelegramServerDraftBasis.self, from: entry.data.dropFirst(serverDraftMarker.count)),
          value.schemaVersion == (threadID == nil ? 1 : 2), value.accountID == accountID, value.chatID == chatID, value.threadID == threadID else {
        throw TelegramComposerDraftPersistenceError.incompatibleData
    }
    return value
}
private nonisolated func exactNative(_ value: SynchronizeableChatInputState?) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
private nonisolated func basisEntry(draft: TelegramComposerDraft, native: SynchronizeableChatInputState?) throws -> PreferencesEntry {
    let value = TelegramServerDraftBasis(schemaVersion: draft.threadID == nil ? 1 : 2, accountID: draft.accountID, chatID: draft.chatID, threadID: draft.threadID, revision: draft.revision, native: native)
    let data = try JSONEncoder().encode(value)
    guard data.count <= 512 * 1024 - serverDraftMarker.count else { throw TelegramComposerDraftPersistenceError.incompatibleData }
    return PreferencesEntry(data: serverDraftMarker + data)
}
private nonisolated func exported(_ draft: TelegramComposerDraft, timestamp: Int32) -> SynchronizeableChatInputState? {
    if draft.text.isEmpty && draft.replyTarget == nil { return nil }
    let reply = draft.replyTarget.map {
        EngineMessageReplySubject(messageId: MessageId(peerId: PeerId($0.peerID), namespace: $0.namespace, id: $0.messageID), quote: $0.quote?.nativeDraftQuote(), todoItemId: nil)
    }
    return SynchronizeableChatInputState(replySubject: reply, text: draft.text, entities: draft.input.formattedText.engineEntities(), timestamp: timestamp, textSelection: nil, messageEffectId: nil, suggestedPost: nil)
}
private nonisolated func imported(_ native: SynchronizeableChatInputState?, transaction: Transaction, accountID: Int64, chatID: Int64, threadID: Int64?) throws -> TelegramComposerDraft {
    guard let native else { return TelegramComposerDraft(accountID: accountID, chatID: chatID, input: .empty, threadID: threadID) }
    // Preserve unsupported server semantics instead of silently flattening them.
    guard native.messageEffectId == nil, native.suggestedPost == nil,
          native.replySubject?.todoItemId == nil,
          native.text.utf8.count <= TelegramComposerDraft.maximumTextBytes else {
        throw TelegramComposerDraftPersistenceError.incompatibleData
    }
    let input = try TelegramComposerInput(formattedText: telegramFormattedText(text: native.text, entities: native.entities))
    let reply = try native.replySubject.map {
        TelegramComposerReplyTarget(peerID: $0.messageId.peerId.toInt64(), namespace: $0.messageId.namespace, messageID: $0.messageId.id,
            threadID: threadID ?? transaction.getMessage($0.messageId)?.threadId, quote: try $0.quote.map(TelegramReplyQuote.init(native:)))
    }
    let draft = TelegramComposerDraft(accountID: accountID, chatID: chatID, input: input, threadID: threadID, replyTarget: reply)
    guard draft.isValid else { throw TelegramComposerDraftPersistenceError.incompatibleData }
    return draft
}

nonisolated func telegramServerDraftUpdate(transaction: Transaction, accountID: Int64, chatID: Int64, threadID: Int64? = nil) throws -> TelegramServerDraftUpdate? {
    guard cloudDraftPeer(chatID) else { return nil }
    let native = try nativeDraft(transaction: transaction, chatID: chatID, threadID: threadID)
    let previous = try basis(transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID)
    let fingerprint = try exactNative(native)
    if let previous, try exactNative(previous.native) == fingerprint { return nil }
    if previous == nil && native == nil { return nil }
    return TelegramServerDraftUpdate(draft: try imported(native, transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID),
        nativeFingerprint: fingerprint, basisRevision: previous?.revision,
        localRevision: try telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID).get()?.revision)
}

enum TelegramServerDraftChoice { case local, remote }
nonisolated func telegramServerDraftResolve(transaction: Transaction, update: TelegramServerDraftUpdate,
    local: TelegramComposerDraft?, choice: TelegramServerDraftChoice) throws -> TelegramComposerDraft {
    let accountID = update.draft.accountID, chatID = update.draft.chatID, threadID = update.draft.threadID
    guard cloudDraftPeer(chatID), update.draft.isValid,
          local.map({ $0.isValid && $0.accountID == accountID && $0.chatID == chatID && $0.threadID == threadID && $0.forwardIntent == nil }) ?? true else {
        throw TelegramComposerDraftPersistenceError.incompatibleData
    }
    let current = try nativeDraft(transaction: transaction, chatID: chatID, threadID: threadID)
    let previous = try basis(transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID)
    let durable = try telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID).get()
    guard try exactNative(current) == update.nativeFingerprint,
          previous?.revision == update.basisRevision, durable?.revision == update.localRevision,
          durable?.forwardIntent == nil else { throw TelegramComposerDraftPersistenceError.serverConflict }
    let chosen: TelegramComposerDraft
    let native: SynchronizeableChatInputState?
    switch choice {
    case .remote:
        chosen = try imported(current, transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID)
        native = current
    case .local:
        guard let local else { throw TelegramComposerDraftPersistenceError.incompatibleData }
        chosen = TelegramComposerDraft(accountID: accountID, chatID: chatID, input: local.input, threadID: threadID, replyTarget: local.replyTarget)
        native = exported(chosen, timestamp: Int32(clamping: Int64(Date().timeIntervalSince1970)))
    }
    let entry = try basisEntry(draft: chosen, native: native)
    let nativeChanged = try exactNative(native) != exactNative(current)
    guard telegramComposerDraftWriteLocal(transaction: transaction, draft: chosen) else { throw TelegramComposerDraftPersistenceError.incompatibleData }
    if nativeChanged {
        addSynchronizeChatInputStateOperation(transaction: transaction, peerId: PeerId(chatID), threadId: threadID)
        _internal_updateChatInputState(transaction: transaction, peerId: PeerId(chatID), threadId: threadID, inputState: native)
    }
    transaction.setPreferencesEntry(key: telegramServerDraftBasisKey(accountID: accountID, chatID: chatID, threadID: threadID), value: entry)
    return chosen
}

/// Read-side reconciliation never exports. A remote clear becomes a retained
/// local tombstone. Started forwards and independently changed local state stop.
nonisolated func telegramServerDraftReconcile(transaction: Transaction, accountID: Int64, chatID: Int64, threadID: Int64? = nil,
    local: TelegramComposerDraft?) throws -> TelegramComposerDraft? {
    guard cloudDraftPeer(chatID) else { return local }
    let native = try nativeDraft(transaction: transaction, chatID: chatID, threadID: threadID)
    let previous = try basis(transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID)
    if let previous, try exactNative(previous.native) == exactNative(native) { return local }
    if let local {
        guard local.forwardIntent == nil else { throw TelegramComposerDraftPersistenceError.serverConflict }
        if let previous {
            guard previous.revision == local.revision else { throw TelegramComposerDraftPersistenceError.serverConflict }
        } else {
            // Existing local-only drafts migrate without losing cursor state.
            let matches = try exactNative(exported(local, timestamp: native?.timestamp ?? 0)) == exactNative(native)
            guard native == nil || matches else {
                throw TelegramComposerDraftPersistenceError.serverConflict
            }
            transaction.setPreferencesEntry(key: telegramServerDraftBasisKey(accountID: accountID, chatID: chatID, threadID: threadID), value: try basisEntry(draft: local, native: native))
            return local
        }
    } else if native == nil { return nil }
    let updated = try imported(native, transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID)
    let entry = try basisEntry(draft: updated, native: native)
    guard telegramComposerDraftWriteLocal(transaction: transaction, draft: updated) else { throw TelegramComposerDraftPersistenceError.incompatibleData }
    transaction.setPreferencesEntry(key: telegramServerDraftBasisKey(accountID: accountID, chatID: chatID, threadID: threadID), value: entry)
    return updated
}

/// Called only after validating/encoding the local write. Enqueue's own clear
/// and another device's newer input cause a conflict rather than data loss.
nonisolated func telegramServerDraftWrite(transaction: Transaction, draft: TelegramComposerDraft) throws {
    guard cloudDraftPeer(draft.chatID) else { return }
    let current = try nativeDraft(transaction: transaction, chatID: draft.chatID, threadID: draft.threadID)
    if let previous = try basis(transaction: transaction, accountID: draft.accountID, chatID: draft.chatID, threadID: draft.threadID) {
        guard try exactNative(previous.native) == exactNative(current) else { throw TelegramComposerDraftPersistenceError.serverConflict }
    } else if current != nil { throw TelegramComposerDraftPersistenceError.serverConflict }
    var native = exported(draft, timestamp: Int32(clamping: Int64(Date().timeIntervalSince1970)))
    // A cursor-only change does not touch the native timestamp or queue another RPC.
    if try exactNative(exported(draft, timestamp: current?.timestamp ?? 0)) == exactNative(current) { native = current }
    let entry = try basisEntry(draft: draft, native: native)
    if try exactNative(native) != exactNative(current) {
        addSynchronizeChatInputStateOperation(transaction: transaction, peerId: PeerId(draft.chatID), threadId: draft.threadID)
        _internal_updateChatInputState(transaction: transaction, peerId: PeerId(draft.chatID), threadId: draft.threadID, inputState: native)
    }
    transaction.setPreferencesEntry(key: telegramServerDraftBasisKey(accountID: draft.accountID, chatID: draft.chatID, threadID: draft.threadID), value: entry)
}
