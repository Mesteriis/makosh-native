import Foundation
import MakoshCore

public struct RemoteCardRef: Equatable, Sendable {
    public var externalID: String
    public var etag: String?
    public init(externalID: String, etag: String?) {
        self.externalID = externalID
        self.etag = etag
    }
}

/// What changed in a book since the cursor. `full` means the whole book was read:
/// a card missing from it is gone.
public struct RemoteCardChanges: Sendable {
    public var cards: [RemoteCard]
    public var removedExternalIDs: [String]
    public var cursor: Data?
    public var full: Bool
    public init(cards: [RemoteCard], removedExternalIDs: [String] = [], cursor: Data?, full: Bool) {
        self.cards = cards
        self.removedExternalIDs = removedExternalIDs
        self.cursor = cursor
        self.full = full
    }
}

public struct PersonBookCapabilities: Equatable, Sendable {
    /// The book can hold a company card.
    public var acceptsOrganizations: Bool
    /// The book adds a person only by phone or by an identity it already knows (Telegram).
    public var requiresPhoneOrPeer: Bool
    /// Makosh can mark its cards and find them again by the mark.
    public var supportsMarker: Bool
    /// The book holds every phone and address Makosh sends, so a value missing from a card it
    /// returns was removed by the user there. Telegram keeps one phone and no address: false.
    public var reportsRemovals: Bool
    public init(acceptsOrganizations: Bool, requiresPhoneOrPeer: Bool, supportsMarker: Bool, reportsRemovals: Bool = true) {
        self.acceptsOrganizations = acceptsOrganizations
        self.requiresPhoneOrPeer = requiresPhoneOrPeer
        self.supportsMarker = supportsMarker
        self.reportsRemovals = reportsRemovals
    }
}

/// One address book, real or synthetic. Every write is one network call; the service
/// journals it before and settles it after, so an adapter never retries by itself.
public protocol PersonBookAdapter: Sendable {
    var capabilities: PersonBookCapabilities { get async }
    func changes(cursor: Data?) async throws -> RemoteCardChanges
    func create(_ card: PersonCard) async throws -> RemoteCardRef
    /// Creates with the person's identity in this book as a hint (Telegram's peer); books without peers ignore it.
    func create(_ card: PersonCard, hint externalID: String?) async throws -> RemoteCardRef
    func update(externalID: String, etag: String?, card: PersonCard) async throws -> RemoteCardRef
    func delete(externalID: String, etag: String?) async throws
    /// The card carrying Makosh's mark for this person, if the book can tell.
    func find(makoshID: UUID) async throws -> RemoteCardRef?
}

extension PersonBookAdapter {
    public func create(_ card: PersonCard, hint externalID: String?) async throws -> RemoteCardRef { try await create(card) }
}
