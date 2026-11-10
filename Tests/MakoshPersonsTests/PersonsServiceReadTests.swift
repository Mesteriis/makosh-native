import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshPersons

final class PersonsServiceReadTests: XCTestCase {
    private var db: PersonsTestDatabase!
    private var persons: PersonStore!
    private var store: PersonsStore!
    private var books: SyntheticBooks!
    private var service: PersonsService!

    override func setUp() async throws {
        db = try personsDatabase()
        persons = try db.persons()
        store = try await personsStore(db)
        books = SyntheticBooks()
        service = PersonsService(
            persons: persons, store: store, vault: PersonsCredentialVault(access: .memory()), adapterFactory: books.factory, google: nil,
            grants: GoogleGrantVault(access: .memory()))
        try await service.open()
    }

    /// Connections live until the actor is freed; release the core store and the worker here.
    override func tearDown() async throws {
        await service?.close()
        service = nil
        store = nil
        persons = nil
        db = nil
    }

    private func connect(
        _ accountID: String, source: Bool = false, cards: [RemoteCard] = []
    ) async throws -> (PersonBook, PersonSyntheticBook) {
        let book = PersonBook(kind: .synthetic, name: accountID, accountID: accountID, isAddressBookSource: source)
        try await store.saveBook(book)
        return (book, books.add(accountID, PersonSyntheticBook(cards: cards)))
    }

    private func remote(_ id: String, name: String, phones: [String] = [], emails: [String] = []) -> RemoteCard {
        RemoteCard(
            externalID: id, etag: "e-\(id)", makoshID: nil,
            imported: ImportedPerson(externalID: id, displayName: name, phones: phones, emails: emails), kind: .person)
    }

    func testBookReadCollectsAndFlagsFromSourceBook() async throws {
        let (book, _) = try await connect(
            "yandex", source: true, cards: [remote("c1", name: "Анна", emails: ["anna@x.ru"]), remote("c2", name: "Борис")])
        let result = try await service.readBook(id: book.id)
        XCTAssertEqual(result.created, 2)
        let all = try persons.persons()
        XCTAssertEqual(all.map(\.displayName), ["Анна", "Борис"])
        XCTAssertTrue(all.allSatisfy { $0.addressBook && $0.addressBookOrigin == .sourceAccount(book.source) })
        let saved = try await store.book(id: book.id)
        XCTAssertNotNil(saved?.cursor)
        let again = try await service.readBook(id: book.id)
        XCTAssertEqual(again.created, 0)
    }

    func testSourceCardIsAdoptedWhenThePersonGetsTheFlag() async throws {
        let (book, synthetic) = try await connect("google", cards: [remote("c1", name: "Анна", emails: ["anna@gmail.com"])])
        _ = try await service.readBook(id: book.id)
        await service.settled()
        let anna = try XCTUnwrap(try persons.persons().first)
        try persons.setAddressBook(personID: anna.id, true, origin: .user)
        let report = await service.writePass()
        XCTAssertEqual(report.confirmed, 1)
        let cards = try await synthetic.changes(cursor: nil).cards
        XCTAssertEqual(cards.count, 1, "the source card is adopted, not duplicated")
        XCTAssertEqual(cards.first?.makoshID, anna.id)
        let entries = try await store.entries(personID: anna.id)
        XCTAssertEqual(entries.map(\.externalID), ["c1"])
    }

    func testPhoneRemovedInBookBecomesFormerAndLeavesOtherBooks() async throws {
        let (a, bookA) = try await connect("a")
        let (_, bookB) = try await connect("b")
        let person = try persons.createPerson(draft: .init(displayName: "Иванов", phones: ["+7 916 000-00-00", "+7 495 111-11-11"]))
        try persons.setAddressBook(personID: person, true, origin: .user)
        _ = await service.writePass()
        let entriesA = try await store.entries(personID: person)
        let externalID = try XCTUnwrap(entriesA.first { $0.bookID == a.id }?.externalID)
        await bookA.editRemotely(externalID: externalID) { $0.phones = ["+7 916 000-00-00"] }
        _ = try await service.readBook(id: a.id)
        let updated = try XCTUnwrap(try persons.person(id: person))
        XCTAssertEqual(updated.phones, ["+7 916 000-00-00"])
        XCTAssertEqual(updated.former.map(\.value), ["+7 495 111-11-11"])
        XCTAssertEqual(updated.former.first?.reason, .removedInBook(a.source))
        await service.settled()
        _ = await service.writePass()
        let cardB = await bookB.card(for: person)
        XCTAssertEqual(cardB?.imported.phones, ["+7 916 000-00-00"])
        let writesA = await bookA.writes
        XCTAssertEqual(writesA.count, 2, "the create, then one update with the shorter card; nothing pushes the phone back")
    }

    func testExternalNameChangeIsAdoptedWhenNotManual() async throws {
        let (a, bookA) = try await connect("a")
        let (_, bookB) = try await connect("b")
        let person = try persons.linkImportedPerson(
            .init(externalID: "42", displayName: "Иванов", phones: ["+7 916 000-00-00"]),
            source: .init(service: "telegram", accountID: "t"),
            fetchedAt: Date(timeIntervalSince1970: 100), contactID: nil)
        try persons.setAddressBook(personID: person, true, origin: .user)
        _ = await service.writePass()
        let entriesA = try await store.entries(personID: person)
        let externalID = try XCTUnwrap(entriesA.first { $0.bookID == a.id }?.externalID)
        await bookA.editRemotely(externalID: externalID) { $0.displayName = "Иванов Пётр" }
        _ = try await service.readBook(id: a.id)
        XCTAssertEqual(try persons.person(id: person)?.displayName, "Иванов Пётр")
        await service.settled()
        _ = await service.writePass()
        let cardB = await bookB.card(for: person)
        XCTAssertEqual(cardB?.imported.displayName, "Иванов Пётр")
    }

    func testRemovedCardBecomesNotManagedWithoutRecreate() async throws {
        let (a, bookA) = try await connect("a")
        let person = try persons.createPerson(draft: .init(displayName: "Иванов", phones: ["+7 916 000-00-00"]))
        try persons.setAddressBook(personID: person, true, origin: .user)
        _ = await service.writePass()
        let personEntries = try await store.entries(personID: person)
        let entry = try XCTUnwrap(personEntries.first)
        await bookA.removeRemotely(externalID: entry.externalID)
        _ = try await service.readBook(id: a.id)
        let after = try await store.entry(id: entry.id)
        XCTAssertEqual(after?.state, .notManaged)
        await service.settled()
        let report = await service.writePass()
        XCTAssertEqual(report.attempted, 0, "a card the user deleted outside Makosh is not recreated by itself")
        try await service.resend(entryID: entry.id)
        await service.settled()
        let card = await bookA.card(for: person)
        XCTAssertNotNil(card, "«Отправить снова» brings the card back")
    }

    func testPollingSkipsPausedAndDisconnectedBooks() async throws {
        let (active, activeBook) = try await connect("a")
        var (paused, pausedBook) = try await connect("b")
        var (down, downBook) = try await connect("c")
        paused.pausedUntil = Date().addingTimeInterval(3600)
        try await store.saveBook(paused)
        down.state = .needsSignIn
        try await store.saveBook(down)
        await service.readAll()
        let activeReads = await activeBook.reads
        let pausedReads = await pausedBook.reads
        let downReads = await downBook.reads
        XCTAssertEqual(activeReads, 1)
        XCTAssertEqual(pausedReads, 0)
        XCTAssertEqual(downReads, 0)
        _ = active
    }

    func testTurningOffSourceFlagClearsOnlyItsPersons() async throws {
        let (first, _) = try await connect("one", source: true, cards: [remote("c1", name: "Анна")])
        let (second, _) = try await connect("two", source: true, cards: [remote("c2", name: "Борис")])
        _ = try await service.readBook(id: first.id)
        _ = try await service.readBook(id: second.id)
        let manual = try persons.createPerson(draft: .init(displayName: "Вера"))
        try persons.setAddressBook(personID: manual, true, origin: .user)
        try await service.setBookOptions(
            id: first.id, readBook: nil, isAddressBookSource: false, acceptsAddressBook: nil, collectConversations: nil)
        let flagged = try persons.persons().filter(\.addressBook).map(\.displayName)
        XCTAssertEqual(flagged, ["Борис", "Вера"])
        let saved = try await store.book(id: first.id)
        XCTAssertEqual(saved?.isAddressBookSource, false)
    }

    func testRemovingABookLeavesEntriesNotManaged() async throws {
        let (book, _) = try await connect("a")
        let person = try persons.createPerson(draft: .init(displayName: "Иванов", phones: ["+7 916 000-00-00"]))
        try persons.setAddressBook(personID: person, true, origin: .user)
        _ = await service.writePass()
        try await service.removeBook(id: book.id)
        let entries = try await store.entries(personID: person)
        XCTAssertEqual(entries.map(\.state), [.notManaged])
        let books = try await store.books()
        XCTAssertTrue(books.isEmpty)
    }

    func testSnapshotJoinsBooksEntriesAttemptsAndBlocked() async throws {
        let telegram = PersonBook(kind: .telegram, name: "Telegram", accountID: "100")
        try await store.saveBook(telegram)
        _ = books.add(
            "100", PersonSyntheticBook(capabilities: .init(acceptsOrganizations: false, requiresPhoneOrPeer: true, supportsMarker: false)))
        let noPhone = try persons.createPerson(draft: .init(displayName: "Анна", emails: ["anna@x.ru"]))
        try persons.setAddressBook(personID: noPhone, true, origin: .user)
        _ = await service.writePass()
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.books.map(\.id), [telegram.id])
        XCTAssertEqual(snapshot.blocked[noPhone]?[telegram.id], .noPhoneOrPeer)
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertTrue(snapshot.openAttempts.isEmpty)
        XCTAssertFalse(snapshot.googleAvailable)
        XCTAssertEqual(snapshot.preferences, PersonsPreferences())
    }
}
