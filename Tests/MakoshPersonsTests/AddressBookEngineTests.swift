import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class AddressBookEngineTests: XCTestCase {
    private let google = PersonBook(kind: .googleContacts, name: "Google", accountID: "subj")
    private let telegram = PersonBook(kind: .telegram, name: "Telegram", accountID: "100")
    private let all = PersonBookCapabilities(acceptsOrganizations: true, requiresPhoneOrPeer: false, supportsMarker: true)
    private let telegramCapabilities = PersonBookCapabilities(acceptsOrganizations: false, requiresPhoneOrPeer: true, supportsMarker: false)

    private func flagged(_ name: String, phones: [String] = [], emails: [String] = [], kind: PersonKind = .person) -> Person {
        var person = Person(displayName: name, phones: phones, emails: emails)
        person.kind = kind
        person.addressBook = true
        return person
    }

    func testDesiredSkipsOrganizationsForTelegramAndPersonsWithoutPhone() {
        let withPhone = flagged("Иванов", phones: ["+7 916 000-00-00"])
        let noPhone = flagged("Анна", emails: ["anna@x.ru"])
        let organization = flagged("ИП Сидоров", emails: ["info@sidorov.ru"], kind: .organization)
        let unflagged = Person(displayName: "Борис", phones: ["+7 1"])
        var deleted = flagged("Удалённый", phones: ["+7 2"])
        deleted.deletedAt = Date()
        let books = [google, telegram]
        let capabilities = [google.id: all, telegram.id: telegramCapabilities]
        let desired = AddressBookEngine.desired(
            persons: [withPhone, noPhone, organization, unflagged, deleted], memberships: [], books: books, capabilities: capabilities,
            sourceIdentities: [:])
        let pairs = Set(
            desired.map {
                "\($0.personID == withPhone.id ? "ivanov" : $0.personID == noPhone.id ? "anna" : $0.personID == organization.id ? "org" : "?") → \($0.bookID == google.id ? "google" : "telegram")"
            })
        XCTAssertEqual(pairs, ["ivanov → google", "ivanov → telegram", "anna → google", "org → google"])
        let blocked = AddressBookEngine.blockedReasons(
            persons: [withPhone, noPhone, organization], books: books, capabilities: capabilities)
        XCTAssertEqual(blocked[noPhone.id]?[telegram.id], .noPhoneOrPeer)
        XCTAssertNil(blocked[withPhone.id])
        XCTAssertNil(blocked[organization.id], "an organization simply does not go to Telegram; nothing is blocked")
    }

    func testTelegramPeerIdentityAllowsAPersonWithoutPhone() {
        let person = flagged("Анна", emails: ["anna@x.ru"])
        let identity = ServiceIdentity(service: "telegram", accountID: "100", externalID: "4242")
        let desired = AddressBookEngine.desired(
            persons: [person], memberships: [], books: [telegram], capabilities: [telegram.id: telegramCapabilities],
            sourceIdentities: [person.id: [identity]])
        XCTAssertEqual(desired.count, 1)
        XCTAssertEqual(desired.first?.bookExternalID, "4242")
    }

    func testBooksThatDoNotAcceptOrAreNotConnectedGetNothing() {
        var off = google
        off.acceptsAddressBook = false
        var down = telegram
        down.state = .needsSignIn
        let person = flagged("Иванов", phones: ["+7 1"])
        let desired = AddressBookEngine.desired(
            persons: [person], memberships: [], books: [off, down], capabilities: [off.id: all, down.id: telegramCapabilities],
            sourceIdentities: [:])
        XCTAssertTrue(desired.isEmpty)
    }

    func testSourceCardIsAdoptedInsteadOfCreated() {
        let person = flagged("Иванов", emails: ["ivanov@gmail.com"])
        let identity = ServiceIdentity(service: "google-contacts", accountID: "subj", externalID: "people/c1")
        let desired = DesiredCard(
            personID: person.id, bookID: google.id, card: PersonCardBuilder.card(for: person, memberships: [], organizations: [:]),
            bookExternalID: "people/c1")
        let remote = RemoteCard(
            externalID: "people/c1", etag: "e1", makoshID: nil, imported: ImportedPerson(externalID: "people/c1", displayName: "Иванов"),
            kind: .person)
        let writes = AddressBookEngine.reconcile(
            desired: [desired], entries: [], remote: [google.id: [remote]], sourceIdentities: [person.id: [identity]])
        XCTAssertEqual(writes, [.adopt(desired, externalID: "people/c1", etag: "e1")])
    }

    func testMarkedCardIsAdoptedByMakoshID() {
        let person = flagged("Иванов", emails: ["ivanov@gmail.com"])
        let desired = DesiredCard(
            personID: person.id, bookID: google.id, card: PersonCardBuilder.card(for: person, memberships: [], organizations: [:]),
            bookExternalID: nil)
        let remote = RemoteCard(
            externalID: "people/c9", etag: "e9", makoshID: person.id,
            imported: ImportedPerson(externalID: "people/c9", displayName: "Иванов"),
            kind: .person)
        let writes = AddressBookEngine.reconcile(desired: [desired], entries: [], remote: [google.id: [remote]], sourceIdentities: [:])
        XCTAssertEqual(writes, [.adopt(desired, externalID: "people/c9", etag: "e9")])
    }

    func testNothingKnownCreates() {
        let person = flagged("Иванов", emails: ["ivanov@gmail.com"])
        let desired = DesiredCard(
            personID: person.id, bookID: google.id, card: PersonCardBuilder.card(for: person, memberships: [], organizations: [:]),
            bookExternalID: nil)
        let writes = AddressBookEngine.reconcile(desired: [desired], entries: [], remote: [:], sourceIdentities: [:])
        XCTAssertEqual(writes, [.create(desired)])
    }

    func testChangedFingerprintUpdatesAndSameFingerprintIsNone() {
        let person = flagged("Иванов", emails: ["ivanov@gmail.com"])
        let card = PersonCardBuilder.card(for: person, memberships: [], organizations: [:])
        let desired = DesiredCard(personID: person.id, bookID: google.id, card: card, bookExternalID: nil)
        let same = PersonBookEntry(
            personID: person.id, bookID: google.id, externalID: "people/c1", etag: "e1", fingerprint: card.fingerprint, state: .managed)
        XCTAssertEqual(AddressBookEngine.reconcile(desired: [desired], entries: [same], remote: [:], sourceIdentities: [:]), [.none])
        var stale = same
        stale.fingerprint = "old"
        XCTAssertEqual(
            AddressBookEngine.reconcile(desired: [desired], entries: [stale], remote: [:], sourceIdentities: [:]),
            [.update(desired, entry: stale)])
    }

    func testUnmanagedEntryIsLeftAlone() {
        let person = flagged("Иванов", emails: ["ivanov@gmail.com"])
        let card = PersonCardBuilder.card(for: person, memberships: [], organizations: [:])
        let desired = DesiredCard(personID: person.id, bookID: google.id, card: card, bookExternalID: nil)
        for state in [PersonBookEntryState.duplicate, .notManaged] {
            let entry = PersonBookEntry(
                personID: person.id, bookID: google.id, externalID: "people/c1", etag: nil, fingerprint: "x", state: state)
            XCTAssertEqual(
                AddressBookEngine.reconcile(desired: [desired], entries: [entry], remote: [:], sourceIdentities: [:]), [.none], "\(state)")
        }
        let removed = PersonBookEntry(
            personID: person.id, bookID: google.id, externalID: "people/c1", etag: nil, fingerprint: "x", state: .removed)
        XCTAssertEqual(
            AddressBookEngine.reconcile(desired: [desired], entries: [removed], remote: [:], sourceIdentities: [:]), [.create(desired)],
            "a removed entry no longer holds the person back")
    }
}
