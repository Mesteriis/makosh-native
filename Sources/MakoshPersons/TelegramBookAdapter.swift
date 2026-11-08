import Foundation
import MakoshCore

/// What the application implements on top of the Telegram engine for one account.
public protocol TelegramContactsBridge: Sendable {
    /// The account's contacts as cards: `externalID` is the peer id.
    func contacts(accountID: String) async throws -> [RemoteCard]
    /// Adds (or renames) a contact by peer, else by phone; returns the peer id. `notInTelegram` when the phone is unknown there.
    func addContact(accountID: String, peerID: String?, phone: String?, givenName: String, familyName: String) async throws -> String
    func deleteContact(accountID: String, peerID: String) async throws
}

/// The contacts of one Telegram account as a book. Telegram carries no Makosh mark: a card is
/// Makosh's only through its entry, and reading is always the whole list.
public struct TelegramBookAdapter: PersonBookAdapter {
    let accountID: String
    let bridge: any TelegramContactsBridge

    public init(accountID: String, bridge: any TelegramContactsBridge) {
        self.accountID = accountID
        self.bridge = bridge
    }

    public var capabilities: PersonBookCapabilities {
        get async { PersonBookCapabilities(acceptsOrganizations: false, requiresPhoneOrPeer: true, supportsMarker: false) }
    }

    public func changes(cursor: Data?) async throws -> RemoteCardChanges {
        RemoteCardChanges(cards: try await bridge.contacts(accountID: accountID), cursor: nil, full: true)
    }

    public func create(_ card: PersonCard) async throws -> RemoteCardRef { try await create(card, hint: nil) }

    public func create(_ card: PersonCard, hint externalID: String?) async throws -> RemoteCardRef {
        let phone = card.phones.first
        guard externalID != nil || phone != nil else { throw PersonsFailure.noPhoneOrPeer }
        let peer = try await bridge.addContact(
            accountID: accountID, peerID: externalID, phone: phone, givenName: card.givenName.isEmpty ? card.displayName : card.givenName,
            familyName: card.familyName)
        return RemoteCardRef(externalID: peer, etag: nil)
    }

    /// Telegram has no edit: adding a known peer again sets its name.
    public func update(externalID: String, etag: String?, card: PersonCard) async throws -> RemoteCardRef {
        let peer = try await bridge.addContact(
            accountID: accountID, peerID: externalID, phone: card.phones.first,
            givenName: card.givenName.isEmpty ? card.displayName : card.givenName, familyName: card.familyName)
        return RemoteCardRef(externalID: peer, etag: nil)
    }

    public func delete(externalID: String, etag: String?) async throws {
        try await bridge.deleteContact(accountID: accountID, peerID: externalID)
    }

    public func find(makoshID: UUID) async throws -> RemoteCardRef? { nil }
}
