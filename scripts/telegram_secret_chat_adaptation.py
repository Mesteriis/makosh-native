# SPDX-License-Identifier: GPL-3.0-or-later
"""Reviewed native source guards and own MIT secret-chat bridge generation."""
import hashlib

CREATE = 'submodules/TelegramCore/Sources/TelegramEngine/Peers/CreateSecretChat.swift'
OUTGOING = 'submodules/TelegramCore/Sources/State/ManagedSecretChatOutgoingOperations.swift'
SOURCE_SHA256 = {
    CREATE: '9e78c8a652da68be24fcd976ee978bd9fefa12dbf04d1c0e4847c06a92b09bfc',
    OUTGOING: '38d672dbe3c89429e877d577a99db219cb3256958c66198560785689f64b1937',
}
ADAPTED_SHA256 = {
    CREATE: 'a947b35ed6a96dbd25d481f98103f7ac8d75184d5a795d27f0c0b69e5e3e3384',
    OUTGOING: '9ba668a49097c2e837351d58bb5f712f742d17651c765c1681d8ea1d6b24108a',
}

def adapt_secret_chat_source(path, source):
    if path not in SOURCE_SHA256:
        raise ValueError('Unsupported native secret source')
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == ADAPTED_SHA256[path]:
        return source
    if digest != SOURCE_SHA256[path]:
        raise ValueError('Unexpected pinned native secret source digest')
    if path == CREATE:
        old = '''                    let aBytes = malloc(256)!
                    let _ = SecRandomCopyBytes(nil, 256, aBytes.assumingMemoryBound(to: UInt8.self))
                    let a = MemoryBuffer(memory: aBytes, capacity: 256, length: 256, freeWhenDone: true)'''
        exponent = 'let ga = MTExp(account.network.encryptionProvider, g, aData, p)!'
        if source.count(old) != 1 or source.count(exponent) != 1:
            raise ValueError('Unexpected native secret creation context')
        source = source.replace(old, '                    guard let a = makoshSecretChatRandomBuffer() else { return .fail(.generic) }')
        source = source.replace(exponent, 'guard let ga = MTExp(account.network.encryptionProvider, g, aData, p) else { return .fail(.generic) }')
    else:
        for layer in (73, 101, 144):
            old = 'private func decryptedEntities' + str(layer) + '('
            if source.count(old) != 1:
                raise ValueError('Unexpected native secret entity context')
            source = source.replace(old, 'func decryptedEntities' + str(layer) + '(')
    if hashlib.sha256(source.encode()).hexdigest() != ADAPTED_SHA256[path]:
        raise ValueError('Unexpected adapted native secret source digest')
    return source

def secret_chat_helper_source():
    return '''// Own Makosh MIT adapter; linked TelegramCore remains GPL-3.0-or-later.
import Foundation
import Security
import Postbox

/// Native creation uses this exact256-byte entropy boundary. Failures produce
/// no exponent; an injectable fill permits deterministic failure coverage.
public func makoshSecretChatRandomBuffer(fill: ((UnsafeMutableRawPointer, Int) -> OSStatus)? = nil) -> MemoryBuffer? {
    guard let memory = malloc(256) else { return nil }
    memset(memory, 0, 256)
    let status = fill?(memory, 256) ?? SecRandomCopyBytes(kSecRandomDefault, 256, memory.assumingMemoryBound(to: UInt8.self))
    guard status == errSecSuccess else { memset(memory, 0, 256); free(memory); return nil }
    return MemoryBuffer(memory: memory, capacity: 256, length: 256, freeWhenDone: true)
}
/// Check the pinned native encoder rather than silently dropping entities.
public func makoshSecretEntitiesAreLossless(_ entities: [MessageTextEntity], layer: Int32) -> Bool {
    guard entities.count <= 1024, let layer = SecretChatLayer(rawValue: layer) else { return false }
    for entity in entities {
        guard entity.range.lowerBound >= 0, entity.range.upperBound <= 4096, !entity.range.isEmpty else { return false }
        switch entity.type {
        case let .Pre(language): if !(language?.isEmpty ?? true) { return false }
        case let .BlockQuote(collapsed): if collapsed { return false }
        case let .CustomEmoji(_, id): if id <= 0 { return false }
        default: break
        }
    }
    switch layer {
    case .layer8, .layer46: return entities.isEmpty
    case .layer73: return decryptedEntities73(entities)?.count == entities.count
    case .layer101: return decryptedEntities101(entities)?.count == entities.count
    case .layer144: return decryptedEntities144(entities)?.count == entities.count
    }
}
/// Own admission policy shared by user sends and timer service messages.
public func makoshSecretSendKeyAvailable(transaction: Transaction, peer: TelegramSecretChat, state: SecretChatState, count: Int) -> Bool {
    guard (1...100).contains(count), peer.embeddedState == .active, state.embeddedState.peerState == .active, state.role == peer.role,
        state.keyFingerprint != nil, !state.keychain.keys.isEmpty,
        Set(state.keychain.keys.map(\\.fingerprint)).count == state.keychain.keys.count,
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
/// Enqueue and prove the native timer service before updating the timer in the
/// same transaction. A local receipt is not a remote Telegram acknowledgement.
public func makoshEnqueueSecretTTL(transaction: Transaction, accountPeerId: PeerId, peerId: PeerId, timeout: Int32?,
    timestamp: Int32, isSupportUser: Bool, admission: (Transaction) -> Bool) -> MessageId? {
    guard accountPeerId.namespace == Namespaces.Peer.CloudUser, accountPeerId.id._internalGetInt64Value() > 0,
          transaction.getPeer(accountPeerId) is TelegramUser, peerId.namespace == Namespaces.Peer.SecretChat,
          let nativeID = Int32(exactly: peerId.id._internalGetInt64Value()), nativeID != 0, timestamp > 0,
          timeout.map({ $0 > 0 }) ?? true, let peer = transaction.getPeer(peerId) as? TelegramSecretChat,
          let state = transaction.getPeerChatState(peerId) as? SecretChatState,
          state.messageAutoremoveTimeout == peer.messageAutoremoveTimeout, timeout != peer.messageAutoremoveTimeout,
          makoshSecretSendKeyAvailable(transaction: transaction, peer: peer, state: state, count: 1), admission(transaction) else { return nil }
    let action = TelegramMediaAction(action: .messageAutoremoveTimeoutUpdated(period: timeout ?? 0, autoSettingSource: nil))
    let message = EnqueueMessage.message(text: "", attributes: [], inlineStickers: [:], mediaReference: .standalone(media: action),
        threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
    let ids = enqueueMessages(transaction: transaction, accountPeerId: accountPeerId, isSupportUser: isSupportUser,
        timestamp: { timestamp }, peerId: peerId, messages: [(true, message)])
    guard ids.count == 1, let id = ids[0], id.peerId == peerId, id.namespace == Namespaces.Message.Local, id.id > 0,
          let stored = transaction.getMessage(id), stored.author?.id == accountPeerId,
          stored.media.count == 1, let storedAction = stored.media.first as? TelegramMediaAction,
          case let .messageAutoremoveTimeoutUpdated(period, source) = storedAction.action, period == (timeout ?? 0), source == nil else { return nil }
    updatePeersCustom(transaction: transaction, peers: [peer.withUpdatedMessageAutoremoveTimeout(timeout)], update: { _, value in value })
    transaction.setPeerChatState(peerId, state: state.withUpdatedMessageAutoremoveTimeout(timeout))
    return id
}
'''
