import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshPersons

/// Books by account id, handed to the service as its adapter factory.
final class SyntheticBooks: @unchecked Sendable {
    private let lock = NSLock()
    private var books: [String: PersonSyntheticBook] = [:]
    func add(_ accountID: String, _ book: PersonSyntheticBook = PersonSyntheticBook()) -> PersonSyntheticBook {
        lock.withLock { books[accountID] = book }
        return book
    }
    func book(_ accountID: String) -> PersonSyntheticBook? { lock.withLock { books[accountID] } }
    var factory: PersonsService.AdapterFactory {
        { book, _ in
            guard let adapter = self.book(book.accountID) else { throw PersonsFailure.notFound }
            return adapter
        }
    }
}

final class PersonsServiceWriteTests: XCTestCase {
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

    private func connect(_ accountID: String, accepts: Bool = true) async throws -> (PersonBook, PersonSyntheticBook) {
        let book = PersonBook(kind: .synthetic, name: accountID, accountID: accountID, acceptsAddressBook: accepts)
        try await store.saveBook(book)
        return (book, books.add(accountID))
    }

    private func flagged(_ name: String, phones: [String] = ["+7 916 000-00-00"], emails: [String] = []) throws -> UUID {
        let id = try persons.createPerson(draft: .init(displayName: name, phones: phones, emails: emails))
        try persons.setAddressBook(personID: id, true, origin: .user)
        return id
    }

    func testFlagCreatesCardsInAcceptingBooksOnly() async throws {
        let (accepting, acceptingBook) = try await connect("a")
        let (refusing, refusingBook) = try await connect("b", accepts: false)
        let person = try flagged("Иванов")
        let report = await service.writePass()
        XCTAssertEqual(report.attempted, 1)
        XCTAssertEqual(report.confirmed, 1)
        let entries = try await store.entries(personID: person)
        XCTAssertEqual(entries.map(\.bookID), [accepting.id])
        XCTAssertEqual(entries.first?.state, .managed)
        XCTAssertEqual(entries.first?.sentValues["phones"], ["+7 916 000-00-00"])
        let card = await acceptingBook.card(for: person)
        XCTAssertEqual(card?.imported.displayName, "Иванов")
        let none = await refusingBook.card(for: person)
        XCTAssertNil(none)
        _ = refusing
        let second = await service.writePass()
        XCTAssertEqual(second.attempted, 0, "an unchanged card is not written twice")
    }

    func testEditAfterCreateUpdatesTheCard() async throws {
        let (_, book) = try await connect("a")
        let person = try flagged("Иванов")
        _ = await service.writePass()
        var draft = try XCTUnwrap(try persons.person(id: person)).draft
        draft.displayName = "Иванов Пётр"
        try persons.updatePerson(id: person, draft: draft)
        let report = await service.writePass()
        XCTAssertEqual(report.confirmed, 1)
        let card = await book.card(for: person)
        XCTAssertEqual(card?.imported.displayName, "Иванов Пётр")
        let writes = await book.writes
        XCTAssertEqual(writes.map { String($0.split(separator: " ")[0]) }, ["create", "update"])
    }

    func testUnknownIsSettledByFindNotResend() async throws {
        let (book, synthetic) = try await connect("a")
        let person = try flagged("Иванов")
        await synthetic.failNext(.unknownOutcome(stage: "put"))
        let report = await service.writePass()
        XCTAssertEqual(report.unknown, 1)
        let open = try await store.attempts(open: true)
        XCTAssertEqual(open.map(\.state), [.unknown])
        let noRetry = await service.writePass()
        XCTAssertEqual(noRetry.attempted, 0, "an open attempt blocks a second write for the same person and book")
        try await service.settleUnknown(bookID: book.id)
        let attempt = try await store.attempt(id: open[0].id)
        XCTAssertEqual(attempt?.state, .confirmed)
        let entries = try await store.entries(personID: person)
        XCTAssertEqual(entries.map(\.state), [.managed])
        let writes = await synthetic.writes
        XCTAssertEqual(writes.filter { $0.hasPrefix("create") }.count, 1)
    }

    func testUnknownNotFoundAfterFullReadIsRecreated() async throws {
        let (book, synthetic) = try await connect("a")
        let person = try flagged("Иванов")
        await synthetic.failNext(.unknownOutcome(stage: "put"), applying: false)
        _ = await service.writePass()
        try await service.settleUnknown(bookID: book.id)
        let attempts = try await store.attempts(personID: person)
        XCTAssertEqual(attempts.map(\.state), [.rejected])
        XCTAssertEqual(attempts.first?.failure, .notFound)
        let report = await service.writePass()
        XCTAssertEqual(report.confirmed, 1)
        let cards = try await synthetic.changes(cursor: nil).cards
        XCTAssertEqual(cards.count, 1, "exactly one card after the recreate")
    }

    func testDismissedUnknownIsRejected() async throws {
        let (_, synthetic) = try await connect("a")
        _ = try flagged("Иванов")
        await synthetic.failNext(.unknownOutcome(stage: "put"))
        _ = await service.writePass()
        let open = try await store.attempts(open: true)
        try await service.dismissAttempt(id: open[0].id)
        let attempt = try await store.attempt(id: open[0].id)
        XCTAssertEqual(attempt?.state, .rejected)
    }

    func testLimitPerBookDefersTheRest() async throws {
        let (book, _) = try await connect("a")
        for index in 0..<7 { _ = try flagged("Персона \(index)", phones: ["+7 916 000-00-\(String(format: "%02d", index))"]) }
        let first = await service.writePass(limitPerBook: 5)
        XCTAssertEqual(first.attempted, 5)
        XCTAssertEqual(first.deferredBooks, [book.id])
        let second = await service.writePass(limitPerBook: 5)
        XCTAssertEqual(second.attempted, 2)
        XCTAssertTrue(second.deferredBooks.isEmpty)
    }

    func testRestartTurnsSentIntoUnknown() async throws {
        let (book, _) = try await connect("a")
        var attempt = PersonAttempt(personID: UUID(), bookID: book.id, entryID: nil, kind: .create, fingerprint: "f")
        try await store.saveAttempt(attempt)
        attempt.state = .sent
        try await store.saveAttempt(attempt)
        await service.close()
        try await service.open()
        let reopened = try await store.attempt(id: attempt.id)
        XCTAssertEqual(reopened?.state, .unknown)
    }

    func testDeleteEverywhereRemovesOnlyManagedAndDuplicateEntries() async throws {
        let (a, bookA) = try await connect("a")
        let (b, bookB) = try await connect("b")
        let person = try flagged("Иванов")
        _ = await service.writePass()
        let personEntries = try await store.entries(personID: person)
        var entryB = try XCTUnwrap(personEntries.first { $0.bookID == b.id })
        entryB.state = .notManaged
        try await store.saveEntry(entryB)
        let attempts = try await service.deleteEverywhere(personID: person)
        XCTAssertEqual(attempts.map(\.state), [.confirmed])
        XCTAssertEqual(attempts.first?.bookID, a.id)
        let gone = await bookA.card(for: person)
        XCTAssertNil(gone)
        let kept = await bookB.card(for: person)
        XCTAssertNotNil(kept, "a card Makosh no longer manages is not touched")
        let entries = try await store.entries(personID: person)
        XCTAssertEqual(Set(entries.map(\.state)), [.removed, .notManaged])
        let after = await service.writePass()
        XCTAssertEqual(after.attempted, 1, "the person still carries the flag, so the removed entry is recreated in book a")
    }

    func testSignInRequiredStopsOneBookOnly() async throws {
        let (a, bookA) = try await connect("a")
        let (b, bookB) = try await connect("b")
        _ = try flagged("Иванов")
        await bookA.failNext(.signInRequired, applying: false)
        let report = await service.writePass()
        XCTAssertEqual(report.confirmed, 1)
        XCTAssertEqual(report.rejected, 1)
        let books = try await store.books()
        XCTAssertEqual(books.first { $0.id == a.id }?.state, .needsSignIn)
        XCTAssertEqual(books.first { $0.id == b.id }?.state, .connected)
        let written = await bookB.writes
        XCTAssertEqual(written.count, 1)
    }

    func testMergeKeepsOneManagedEntryAndMarksTheOtherDuplicate() async throws {
        let (_, book) = try await connect("a")
        let survivor = try flagged("Иванов", phones: ["+7 916 000-00-01"])
        let removed = try flagged("Иванов П.", phones: ["+7 916 000-00-02"])
        _ = await service.writePass()
        try await service.mergePersons(survivorID: survivor, removedID: removed)
        let entries = try await store.entries(personID: survivor)
        XCTAssertEqual(Set(entries.map(\.state)), [.managed, .duplicate])
        XCTAssertEqual(entries.first { $0.state == .duplicate }?.mergedFromPersonID, removed)
        let report = await service.writePass()
        XCTAssertEqual(report.attempted, 1, "the surviving card is updated with the merged phones; no new card")
        let cards = try await book.changes(cursor: nil).cards
        XCTAssertEqual(cards.count, 2)
        try await service.undoMerge(id: try XCTUnwrap(try persons.mergeHistory().first?.id))
        let back = try await store.entries(personID: removed)
        XCTAssertEqual(back.map(\.state), [.managed])
        XCTAssertNil(back.first?.mergedFromPersonID)
    }

    func testDeleteDuplicateEntry() async throws {
        let (_, book) = try await connect("a")
        let survivor = try flagged("Иванов", phones: ["+7 916 000-00-01"])
        let removed = try flagged("Иванов П.", phones: ["+7 916 000-00-02"])
        _ = await service.writePass()
        try await service.mergePersons(survivorID: survivor, removedID: removed)
        let survivorEntries = try await store.entries(personID: survivor)
        let duplicate = try XCTUnwrap(survivorEntries.first { $0.state == .duplicate })
        try await service.deleteDuplicateEntry(id: duplicate.id)
        let entry = try await store.entry(id: duplicate.id)
        XCTAssertEqual(entry?.state, .removed)
        let cards = try await book.changes(cursor: nil).cards
        XCTAssertEqual(cards.count, 1)
    }
}
