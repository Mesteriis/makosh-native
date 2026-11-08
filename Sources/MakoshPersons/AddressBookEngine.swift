import Foundation
import MakoshCore

/// One card a book should hold: a flagged person in a book that accepts it.
public struct DesiredCard: Equatable, Sendable {
    public var personID: UUID
    public var bookID: UUID
    public var card: PersonCard
    /// The person's identity in this book (Telegram's peer, a CardDAV href), when a source gave one.
    public var bookExternalID: String?
    public init(personID: UUID, bookID: UUID, card: PersonCard, bookExternalID: String?) {
        self.personID = personID
        self.bookID = bookID
        self.card = card
        self.bookExternalID = bookExternalID
    }
}

/// What the reconciliation asks the runner to do for one desired card.
public enum PersonWrite: Equatable, Sendable {
    case create(DesiredCard)
    /// Take over a card the book already holds: the person's source card, or one carrying Makosh's mark.
    case adopt(DesiredCard, externalID: String, etag: String?)
    case update(DesiredCard, entry: PersonBookEntry)
    case none
}

/// Pure rules: which persons go to which books, and what each book needs to receive.
public enum AddressBookEngine {
    static func fits(_ person: Person, book: PersonBook, capabilities: PersonBookCapabilities, identities: [ServiceIdentity]) -> Bool? {
        guard book.kind.isBook, book.acceptsAddressBook, book.state == .connected else { return nil }
        if person.kind == .organization { return capabilities.acceptsOrganizations ? true : nil }
        if capabilities.requiresPhoneOrPeer {
            return !person.phones.isEmpty || identities.contains { $0.service == book.kind.service && $0.accountID == book.accountID }
        }
        return true
    }

    static func bookIdentity(_ identities: [ServiceIdentity], book: PersonBook) -> ServiceIdentity? {
        identities.first { $0.service == book.kind.service && $0.accountID == book.accountID }
    }

    /// Active flagged persons × accepting connected books, minus what a book cannot hold.
    public static func desired(
        persons: [Person], memberships: [PersonMembership], books: [PersonBook], capabilities: [UUID: PersonBookCapabilities],
        sourceIdentities: [UUID: [ServiceIdentity]]
    ) -> [DesiredCard] {
        let organizations = Dictionary(uniqueKeysWithValues: persons.filter { $0.kind == .organization }.map { ($0.id, $0) })
        var result: [DesiredCard] = []
        for person in persons where person.addressBook && person.isActive {
            let identities = sourceIdentities[person.id] ?? person.identities
            let card = PersonCardBuilder.card(for: person, memberships: memberships, organizations: organizations)
            for book in books {
                guard let capability = capabilities[book.id],
                    fits(person, book: book, capabilities: capability, identities: identities) == true
                else { continue }
                result.append(
                    DesiredCard(
                        personID: person.id, bookID: book.id, card: card, bookExternalID: bookIdentity(identities, book: book)?.externalID))
            }
        }
        return result
    }

    /// Why a flagged person cannot reach a book: today only «no phone or peer» for Telegram.
    public static func blockedReasons(
        persons: [Person], books: [PersonBook], capabilities: [UUID: PersonBookCapabilities]
    ) -> [UUID: [UUID: PersonsFailure]] {
        var result: [UUID: [UUID: PersonsFailure]] = [:]
        for person in persons where person.addressBook && person.isActive && person.kind == .person {
            for book in books {
                guard let capability = capabilities[book.id],
                    fits(person, book: book, capabilities: capability, identities: person.identities) == false
                else { continue }
                result[person.id, default: [:]][book.id] = .noPhoneOrPeer
            }
        }
        return result
    }

    /// Managed entries are kept current; a person without one adopts its own source card or a
    /// marked card, else gets a new one. Duplicate and not-managed entries hold the person back.
    public static func reconcile(
        desired: [DesiredCard], entries: [PersonBookEntry], remote: [UUID: [RemoteCard]], sourceIdentities: [UUID: [ServiceIdentity]]
    ) -> [PersonWrite] {
        desired.map { wanted in
            let own = entries.filter { $0.personID == wanted.personID && $0.bookID == wanted.bookID }
            if let managed = own.first(where: { $0.state == .managed }) {
                return managed.fingerprint == wanted.card.fingerprint ? .none : .update(wanted, entry: managed)
            }
            if own.contains(where: { $0.state == .duplicate || $0.state == .notManaged }) { return .none }
            let cards = remote[wanted.bookID] ?? []
            if let marked = cards.first(where: { $0.makoshID == wanted.personID }) {
                return .adopt(wanted, externalID: marked.externalID, etag: marked.etag)
            }
            if let externalID = wanted.bookExternalID, let source = cards.first(where: { $0.externalID == externalID }) {
                return .adopt(wanted, externalID: source.externalID, etag: source.etag)
            }
            return .create(wanted)
        }
    }
}
