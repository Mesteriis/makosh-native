import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

nonisolated func telegramConversationCapabilities(transaction: Transaction, accountID: Int64,
    chatID: Int64) -> Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError> {
    let account = PeerId(accountID), id = PeerId(chatID)
    guard account.namespace == Namespaces.Peer.CloudUser, account.id._internalGetInt64Value() > 0,
        id.id._internalGetInt64Value() > 0 else { return .failure(.incompatible) }
    guard let peer = transaction.getPeer(id), peer.id == id else { return .failure(.unavailable) }
    let cache = transaction.getPeerCachedData(peerId: id)
    var fee: TelegramMessageFee
    var secret: TelegramSecretConversation?
    if let user = peer as? TelegramUser, id.namespace == Namespaces.Peer.CloudUser {
        // Saved Messages is the exact trusted account, not an unknown contact.
        if id == account { fee = .free }
        else if let data = cache as? CachedUserData {
            if let price = data.sendPaidMessageStars { fee = messageFee(price) }
            else { fee = user.flags.contains(.requireStars) ? .unavailable : .free }
        } else { fee = .unavailable }
    } else if let group = peer as? TelegramGroup, id.namespace == Namespaces.Peer.CloudGroup {
        guard group.migrationReference == nil, cache == nil || cache is CachedGroupData else { return .failure(.unsupported) }
        fee = .free
    } else if let channel = peer as? TelegramChannel, id.namespace == Namespaces.Peer.CloudChannel {
        guard !channel.flags.contains(.isMonoforum) else { return .failure(.unsupported) }
        if channel.flags.contains(.isCreator) || channel.adminRights != nil { fee = .free }
        else if let data = cache as? CachedChannelData {
            fee = (data.sendPaidMessageStars ?? channel.sendPaidMessageStars).map(messageFee) ?? .free
        } else { fee = .unavailable }
    } else if let peer = peer as? TelegramSecretChat, id.namespace == Namespaces.Peer.SecretChat {
        guard peer.regularPeerId.namespace == Namespaces.Peer.CloudUser,
            peer.regularPeerId.id._internalGetInt64Value() > 0,
            let participant = transaction.getPeer(peer.regularPeerId) as? TelegramUser else { return .failure(.incompatible) }
        let native = transaction.getPeerChatState(id) as? SecretChatState
        if let native {
            guard native.role == peer.role, native.embeddedState.peerState == peer.embeddedState else { return .failure(.incompatible) }
        }
        let state: TelegramSecretConversation.State
        switch peer.embeddedState {
        case .handshake: state = .handshake
        case .active: state = .active
        case .terminated: state = .terminated
        }
        let verification = native?.keyFingerprint.flatMap {
            TelegramSecretChatVerification(sha1: $0.sha1.data(), sha256: $0.sha256.data())
        }
        secret = .init(regularPeerID: peer.regularPeerId.toInt64(), participantTitle: telegramPeerTitle(participant),
            state: state, verification: state == .active ? verification : nil)
        fee = .free
    } else { return .failure(.unsupported) }
    return .success(.init(accountID: accountID, chatID: chatID, messageFee: fee, secret: secret))
}

private nonisolated func messageFee(_ value: StarsAmount) -> TelegramMessageFee {
    guard value.nanos == 0, value.value >= 0 else { return .unavailable }
    return value.value == 0 ? .free : .stars(value.value)
}

nonisolated func telegramConversationCapabilitiesSignal(postbox: Postbox, accountID: Int64,
    chatID: Int64) -> Signal<Result<TelegramConversationCapabilities, TelegramConversationCapabilitiesError>, NoError> {
    let id = PeerId(chatID)
    // Peer view also tracks the secret chat's associated participant title.
    let keys: [PostboxViewKey] = [.basicPeer(id), .cachedPeerData(peerId: id),
        .peerChatState(peerId: id), .peer(peerId: id, components: [])]
    return postbox.combinedView(keys: keys)
        |> mapToSignal { _ in
            postbox.transaction { telegramConversationCapabilities(transaction: $0, accountID: accountID, chatID: chatID) }
        }
        |> distinctUntilChanged
        |> deliverOnMainQueue
}
