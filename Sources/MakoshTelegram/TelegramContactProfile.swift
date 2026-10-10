import Foundation
import MakoshCore
import Postbox
import TelegramCore
import SwiftSignalKit

public enum TelegramContactProfileState: Equatable, Sendable {
    case idle, loading, ready(TelegramContactProfile), unavailable(String)
}

// Define the transaction body outside MainActor: the legacy engine runs this
// ordinary escaping closure on its own Postbox queue, before main delivery.
func telegramContactProfilePeer(postbox: Postbox, peerID: Int64) -> Signal<Peer?, NoError> {
    postbox.transaction { transaction in transaction.getPeer(PeerId(peerID)) }
}

/// A source observation, scoped to the explicitly selected Telegram account.
public struct TelegramContactProfile: Equatable, Sendable {
    public let accountID: Int64
    public let peerID: Int64
    public let displayName: String
    public let username: String?
    public let phone: String?
    public let isBot: Bool
    public let observedAt: Date

    public init(accountID: Int64, peerID: Int64, displayName: String, username: String?,
                phone: String?, isBot: Bool, observedAt: Date) {
        self.accountID = accountID
        self.peerID = peerID
        self.displayName = displayName
        self.username = username
        self.phone = phone
        self.isBot = isBot
        self.observedAt = observedAt
    }

    public var dossierIdentity: ServiceIdentity {
        ServiceIdentity(service: "telegram", accountID: String(accountID), externalID: String(peerID))
    }

    /// Usernames remain profile display data; the dossier schema has no username field.
    public var dossierImport: ImportedContact {
        ImportedContact(externalID: String(peerID), displayName: displayName,
            phones: phone.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
    }
}

@MainActor public func telegramContactProfile(peer: Peer, accountID: Int64,
                                            observedAt: Date) -> TelegramContactProfile? {
    guard let user = peer as? TelegramUser, user.id.namespace == Namespaces.Peer.CloudUser else { return nil }
    return TelegramContactProfile(accountID: accountID, peerID: user.id.toInt64(),
        displayName: [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
        username: user.username, phone: user.phone, isBot: user.botInfo != nil, observedAt: observedAt)
}
