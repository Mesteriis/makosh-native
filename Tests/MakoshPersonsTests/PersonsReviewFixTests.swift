import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshPersons

/// Findings of the whole-branch review, each pinned by the test that reproduced it.
final class PersonsReviewFixTests: XCTestCase {
    private var db: PersonsTestDatabase!
    private var persons: PersonStore!
    private var store: PersonsStore!
    private var books: SyntheticBooks!
    private var bridge: FakeTelegramBridge!
    private var service: PersonsService!

    override func setUp() async throws {
        db = try personsDatabase()
        persons = try db.persons()
        store = try await personsStore(db)
        books = SyntheticBooks()
        bridge = FakeTelegramBridge()
        service = makeService()
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

    private func makeService() -> PersonsService {
        let books = books!, bridge = bridge!
        return PersonsService(
            persons: persons, store: store, vault: PersonsCredentialVault(access: .memory()),
            adapterFactory: { book, _ in
                if book.kind == .telegram { return TelegramBookAdapter(accountID: book.accountID, bridge: bridge) }
                guard let adapter = books.book(book.accountID) else { throw PersonsFailure.notFound }
                return adapter
            }, google: nil, grants: GoogleGrantVault(access: .memory()))
    }

    private func connect(_ accountID: String, cards: [RemoteCard] = []) async throws -> (PersonBook, PersonSyntheticBook) {
        let book = PersonBook(kind: .synthetic, name: accountID, accountID: accountID, acceptsAddressBook: true)
        try await store.saveBook(book)
        return (book, books.add(accountID, PersonSyntheticBook(cards: cards)))
    }

    private func telegramBook() async throws -> PersonBook {
        let book = PersonBook(kind: .telegram, name: "Telegram", accountID: "100", acceptsAddressBook: true)
        try await store.saveBook(book)
        return book
    }

    private func flagged(_ name: String, phones: [String], emails: [String] = []) throws -> UUID {
        let id = try persons.createPerson(draft: .init(displayName: name, phones: phones, emails: emails))
        try persons.setAddressBook(personID: id, true, origin: .user)
        return id
    }

    func testTelegramReadDoesNotRetireEmailsOrSecondPhone() async throws {
        let book = try await telegramBook()
        let person = try flagged("Иванов", phones: ["+7 916 000-00-00", "+7 916 000-00-01"], emails: ["ivanov@x.ru"])
        let report = await service.writePass()
        XCTAssertEqual(report.confirmed, 1)
        _ = try await service.readBook(id: book.id)
        let after = try XCTUnwrap(try persons.person(id: person))
        XCTAssertTrue(after.former.isEmpty, "a book that holds one phone and no e-mail reports no removals")
        XCTAssertEqual(after.emails, ["ivanov@x.ru"])
        XCTAssertEqual(after.phones.count, 2)
    }

    func testLocalFailureAfterServerCreateLeavesAttemptUnknownAndAdoptsOnNextPass() async throws {
        let (book, synthetic) = try await connect("a")
        // Another person's old card already carries the id the book will hand out next: the card is created
        // on the server, and only the local entry fails.
        let stranger = try persons.createPerson(draft: .init(displayName: "Чужой"))
        try await store.saveEntry(
            PersonBookEntry(personID: stranger, bookID: book.id, externalID: "syn-1", etag: nil, fingerprint: "x", state: .removed))
        let person = try persons.createPerson(draft: .init(displayName: "Иванов", phones: ["+7 916 000-00-00"]))
        try persons.setAddressBook(personID: person, true, origin: .user)
        let first = await service.writePass()
        XCTAssertEqual(first.attempted, 1)
        XCTAssertEqual(first.unknown, 1, "the book answered: not a refusal")
        let firstStates = try await store.attempts(personID: person).map(\.state)
        XCTAssertEqual(firstStates, [.unknown])
        let writes = await synthetic.writes
        XCTAssertEqual(writes, ["create syn-1"])

        let second = await service.writePass()
        XCTAssertEqual(second.attempted, 0, "settled by reading the mark, never sent again")
        let secondStates = try await store.attempts(personID: person).map(\.state)
        XCTAssertEqual(secondStates, [.confirmed])
        let entries = try await store.entries(personID: person)
        XCTAssertEqual(entries.map(\.state), [.managed])
        XCTAssertEqual(entries.map(\.externalID), ["syn-1"])
        let writesAfter = await synthetic.writes
        XCTAssertEqual(writesAfter, ["create syn-1"])
        let cards = try await synthetic.changes(cursor: nil).cards
        XCTAssertEqual(cards.count, 1, "one card, not a duplicate")
    }

    func testFlagAfterRestartAdoptsSourceCardInsteadOfCreating() async throws {
        let card = RemoteCard(
            externalID: "x", etag: "e1", makoshID: nil,
            imported: ImportedPerson(externalID: "x", displayName: "Анна", phones: ["+7 916 100-00-01"]), kind: .person)
        let (book, synthetic) = try await connect("a", cards: [card])
        _ = try await service.readBook(id: book.id)
        let person = try XCTUnwrap(try persons.persons().first)
        await service.close()
        service = makeService()
        try await service.open()
        try persons.setAddressBook(personID: person.id, true, origin: .user)
        let report = await service.writePass()
        XCTAssertEqual(report.confirmed, 1)
        let cards = try await synthetic.changes(cursor: nil).cards
        XCTAssertEqual(cards.count, 1, "the person's own card is adopted, not duplicated, after a restart")
        let writes = await synthetic.writes
        XCTAssertEqual(writes, ["update x"])
    }

    func testUnknownIsSettledByTheNextPass() async throws {
        let (_, synthetic) = try await connect("a")
        let person = try flagged("Иванов", phones: ["+7 916 000-00-00"])
        await synthetic.failNext(.unknownOutcome(stage: "put"))
        let first = await service.writePass()
        XCTAssertEqual(first.unknown, 1)
        let next = await service.writePass()
        XCTAssertEqual(next.attempted, 0)
        let attempts = try await store.attempts(personID: person)
        XCTAssertEqual(attempts.map(\.state), [.confirmed], "the next pass settles the unknown attempt by the mark")
        let entries = try await store.entries(personID: person)
        XCTAssertEqual(entries.map(\.state), [.managed])
        let writes = await synthetic.writes
        XCTAssertEqual(writes.filter { $0.hasPrefix("create") }.count, 1)
    }

    func testTelegramUnknownIsSettledByPeerPresence() async throws {
        _ = try await telegramBook()
        let person = try flagged("Иванов", phones: ["+7 916 000-00-00"])
        await bridge.setFailAfterApply(.unknownOutcome(stage: "import"))
        let first = await service.writePass()
        XCTAssertEqual(first.unknown, 1)
        _ = await service.writePass()
        let attempts = try await store.attempts(personID: person)
        XCTAssertEqual(attempts.map(\.state), [.confirmed], "Telegram settles by the peer being among the contacts")
        let entries = try await store.entries(personID: person)
        XCTAssertEqual(entries.map(\.externalID), ["4242"])
        let calls = await bridge.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("add") }.count, 1, "never resent")
    }

    func testRejectedWriteIsNotRepeatedUntilTheCardChanges() async throws {
        let (_, synthetic) = try await connect("a")
        let person = try flagged("Иванов", phones: ["+7 916 000-00-00"])
        await synthetic.failNext(.rejected(code: 400, stage: "put"), applying: false)
        let first = await service.writePass()
        XCTAssertEqual(first.rejected, 1)
        let again = await service.writePass()
        XCTAssertEqual(again.attempted, 0, "a rejected card is not resent while it is unchanged")
        var draft = try XCTUnwrap(try persons.person(id: person)).draft
        draft.phones = ["+7 916 000-00-02"]
        try persons.updatePerson(id: person, draft: draft)
        let changed = await service.writePass()
        XCTAssertEqual(changed.confirmed, 1)
        let cards = try await synthetic.changes(cursor: nil).cards
        XCTAssertEqual(cards.count, 1)
    }
}
