import Foundation
import CryptoKit
import Postbox
import TelegramCore

private nonisolated func secretRevision(_ encoder: PostboxEncoder) -> String {
    SHA256.hash(data: encoder.makeData()).map { String(format: "%02x", $0) }.joined()
}
nonisolated func telegramSecretCreationBasis(peer: TelegramUser, accountID: Int64, premiumRequired: Bool,
    existingSecretID: Int64? = nil) -> TelegramSecretCreationBasis? {
    guard telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser,
          telegramManagementPeerID(peer.id.toInt64())?.namespace == Namespaces.Peer.CloudUser,
          peer.id.toInt64() != accountID, !peer.isDeleted, peer.botInfo == nil else { return nil }
    let usableHash: Bool
    if case let .personal(hash) = peer.accessHash { usableHash = hash != 0 } else { usableHash = false }
    let encoder = PostboxEncoder(); peer.encode(encoder)
    encoder.encodeInt64(accountID, forKey: "makoshAccount")
    encoder.encodeBool(premiumRequired, forKey: "makoshPremium")
    if let existingSecretID { encoder.encodeInt64(existingSecretID, forKey: "makoshExisting") }
    var value = TelegramSecretCreationBasis(accountID: accountID, peerID: peer.id.toInt64(), title: telegramPeerTitle(peer),
        username: peer.username, canCreate: usableHash && !premiumRequired, premiumRequired: premiumRequired, revision: secretRevision(encoder))
    value.existingSecretID = existingSecretID
    return value.isValid ? value : nil
}
nonisolated func telegramSecretLayer(_ state: SecretChatState) -> Int32? {
    switch state.embeddedState {
    case .terminated, .handshake: return nil
    case .basicLayer: return 8
    case let .sequenceBasedLayer(sequence): return sequence.layerNegotiationState.activeLayer.rawValue
    }
}
nonisolated func telegramSecretSessionSnapshot(transaction: Transaction, accountID: Int64, chatID: Int64) -> TelegramSecretSessionSnapshot? {
    guard telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser,
          let id = telegramSecretPeerID(chatID),
          case let .success(capabilities) = telegramConversationCapabilities(transaction: transaction, accountID: accountID, chatID: chatID),
          let secret = capabilities.secret, let peer = transaction.getPeer(id) as? TelegramSecretChat,
          let participant = transaction.getPeer(peer.regularPeerId) as? TelegramUser else { return nil }
    let state = transaction.getPeerChatState(id) as? SecretChatState
    if let state { guard state.messageAutoremoveTimeout == peer.messageAutoremoveTimeout else { return nil } }
    let layer = state.flatMap(telegramSecretLayer)
    let encoder = PostboxEncoder(); peer.encode(encoder); participant.encode(encoder)
    encoder.encodeInt64(accountID, forKey: "makoshAccount")
    encoder.encodeInt32(layer ?? 0, forKey: "makoshLayer")
    if let fingerprint = secret.verification { encoder.encodeData(fingerprint.sha1 + fingerprint.sha256, forKey: "makoshVerification") }
    let usable = state.map { makoshSecretSendKeyAvailable(transaction: transaction, peer: peer, state: $0, count: 1) } ?? false
    encoder.encodeBool(usable, forKey: "makoshUsable")
    let value = TelegramSecretSessionSnapshot(accountID: accountID, chatID: chatID, regularPeerID: peer.regularPeerId.toInt64(),
        title: secret.participantTitle, state: secret.state, verification: secret.verification,
        layer: layer, ttl: peer.messageAutoremoveTimeout, keyAvailable: usable, revision: secretRevision(encoder))
    return value.isValid ? value : nil
}
