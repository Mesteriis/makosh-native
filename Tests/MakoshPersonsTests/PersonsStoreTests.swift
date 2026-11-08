import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class PersonsStoreTests: XCTestCase {
    func testOpenCreatesTablesAndMeta() async throws {
        let db = try personsDatabase()
        _ = try await personsStore(db)
        let tables = try db.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema='\(db.schema)' AND table_name LIKE 'persons_%' ORDER BY 1")
        XCTAssertEqual(
            tables.map { $0[0] },
            ["persons_attempts", "persons_book_entries", "persons_books", "persons_cursors", "persons_meta", "persons_preferences"])
        XCTAssertEqual(try db.execute("SELECT version::text FROM persons_meta WHERE id=1"), [["1"]])
    }

    func testBookRoundTripCarriesNoSecrets() async throws {
        let store = try await personsStore(try personsDatabase())
        var book = PersonBook(kind: .carddav, name: "Яндекс", accountID: UUID().uuidString)
        book.caldavServer = URL(string: "https://carddav.yandex.ru")
        book.caldavLogin = "me@ya.ru"
        book.isAddressBookSource = true
        book.cursor = Data("sync-1".utf8)
        try await store.saveBook(book)
        let read = try await store.books()
        XCTAssertEqual(read, [book])
        XCTAssertEqual(book.source, ImportSource(service: "carddav", accountID: book.accountID))
        XCTAssertTrue(book.kind.isBook)
        XCTAssertFalse(PersonBookKind.mail.isBook)
        let mirror = String(reflecting: book)
        XCTAssertFalse(mirror.lowercased().contains("password"))
        try await store.removeBook(id: book.id)
        let gone = try await store.books()
        XCTAssertTrue(gone.isEmpty)
    }

    func testEntryUniquenessPerBookAndExternalID() async throws {
        let store = try await personsStore(try personsDatabase())
        let book = PersonBook(kind: .synthetic, name: "S", accountID: "s")
        try await store.saveBook(book)
        let person = UUID(), other = UUID()
        let entry = PersonBookEntry(
            personID: person, bookID: book.id, externalID: "card-1", etag: "e1", fingerprint: "f1", state: .managed,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000.5))
        try await store.saveEntry(entry)
        let found = try await store.entry(bookID: book.id, externalID: "card-1")
        XCTAssertEqual(found, entry)
        let duplicate = PersonBookEntry(
            personID: other, bookID: book.id, externalID: "card-1", etag: nil, fingerprint: "f2", state: .managed)
        do {
            try await store.saveEntry(duplicate)
            XCTFail("one external card belongs to one person")
        } catch { XCTAssertEqual(error as? PersonsFailure, .invalidInput("entry"), "\(error)") }
        let secondManaged = PersonBookEntry(
            personID: person, bookID: book.id, externalID: "card-2", etag: nil, fingerprint: "f3", state: .managed)
        do {
            try await store.saveEntry(secondManaged)
            XCTFail("one person has one managed card per book")
        } catch { XCTAssertEqual(error as? PersonsFailure, .invalidInput("entry"), "\(error)") }
        let duplicateState = PersonBookEntry(
            personID: person, bookID: book.id, externalID: "card-2", etag: nil, fingerprint: "f3", state: .duplicate)
        try await store.saveEntry(duplicateState)
        let byPerson = try await store.entries(personID: person)
        XCTAssertEqual(byPerson.map(\.externalID), ["card-1", "card-2"])
        let byBook = try await store.entries(bookID: book.id)
        XCTAssertEqual(byBook.count, 2)
    }

    func testAttemptTransitionsAreRestricted() async throws {
        let store = try await personsStore(try personsDatabase())
        let book = PersonBook(kind: .synthetic, name: "S", accountID: "s")
        try await store.saveBook(book)
        var attempt = PersonAttempt(personID: UUID(), bookID: book.id, entryID: nil, kind: .create, fingerprint: "f")
        try await store.saveAttempt(attempt)
        attempt.state = .confirmed
        do {
            try await store.saveAttempt(attempt)
            XCTFail("queued → confirmed is not a move")
        } catch { XCTAssertEqual(error as? PersonsFailure, .invalidInput("attempt transition"), "\(error)") }
        attempt.state = .sent
        try await store.saveAttempt(attempt)
        attempt.state = .unknown
        try await store.saveAttempt(attempt)
        attempt.state = .confirmed
        try await store.saveAttempt(attempt)
        let stored = try await store.attempt(id: attempt.id)
        XCTAssertEqual(stored?.state, .confirmed)
        XCTAssertNotNil(stored?.resolvedAt)
        let open = try await store.attempts(open: true)
        XCTAssertTrue(open.isEmpty)
        XCTAssertTrue(PersonAttemptState.unknown.isOpen)
        XCTAssertFalse(PersonAttemptState.rejected.isOpen)
    }

    func testSentBecomesUnknownOnOpen() async throws {
        let db = try personsDatabase()
        let store = try await personsStore(db)
        let book = PersonBook(kind: .synthetic, name: "S", accountID: "s")
        try await store.saveBook(book)
        var attempt = PersonAttempt(personID: UUID(), bookID: book.id, entryID: nil, kind: .update, fingerprint: "f")
        try await store.saveAttempt(attempt)
        attempt.state = .sent
        try await store.saveAttempt(attempt)
        await store.close()
        let reopened = try await personsStore(db)
        let after = try await reopened.attempt(id: attempt.id)
        XCTAssertEqual(after?.state, .unknown)
        XCTAssertEqual(after?.failure, .unknownOutcome(stage: "restart"))
    }

    func testCursorPerSourceAndScope() async throws {
        let store = try await personsStore(try personsDatabase())
        let source = ImportSource(service: "mail", accountID: "a")
        let inbox = PersonCollectionCursor(source: source, scope: "INBOX", value: Data("10".utf8))
        let sent = PersonCollectionCursor(source: source, scope: "Sent", value: Data("3".utf8))
        try await store.saveCursor(inbox)
        try await store.saveCursor(sent)
        let readInbox = try await store.cursor(source: source, scope: "INBOX")
        XCTAssertEqual(readInbox?.value, Data("10".utf8))
        let readSent = try await store.cursor(source: source, scope: "Sent")
        XCTAssertEqual(readSent?.value, Data("3".utf8))
        let missing = try await store.cursor(source: ImportSource(service: "mail", accountID: "b"), scope: "INBOX")
        XCTAssertNil(missing)
        var moved = inbox
        moved.value = Data("11".utf8)
        try await store.saveCursor(moved)
        let readMoved = try await store.cursor(source: source, scope: "INBOX")
        XCTAssertEqual(readMoved?.value, Data("11".utf8))
    }

    func testPreferencesDefaults() async throws {
        let store = try await personsStore(try personsDatabase())
        let defaults = try await store.preferences()
        XCTAssertEqual(defaults, PersonsPreferences())
        XCTAssertEqual(defaults.pollIntervalSeconds, 600)
        XCTAssertTrue(defaults.domainRuleEnabled)
        XCTAssertTrue(defaults.companyRuleEnabled)
        XCTAssertEqual(defaults.filter, "all")
        var changed = defaults
        changed.extraStopDomains = ["corp.test"]
        changed.expandedOrganizations = [UUID()]
        try await store.savePreferences(changed)
        let read = try await store.preferences()
        XCTAssertEqual(read, changed)
    }
}
