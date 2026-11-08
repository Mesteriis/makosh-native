import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class PersonSyntheticBookTests: XCTestCase {
    private let id = UUID()

    private func card(_ name: String = "Иванов Пётр", phones: [String] = ["+7 916 000-00-00"]) -> PersonCard {
        PersonCard(
            makoshID: id, kind: .person, displayName: name, givenName: "Пётр", familyName: "Иванов", middleName: "", phones: phones,
            emails: ["ivanov@sidorov.ru"], organization: "", jobTitle: "")
    }

    func testCreateUpdateDeleteAndFind() async throws {
        let book = PersonSyntheticBook()
        let created = try await book.create(card())
        XCTAssertFalse(created.externalID.isEmpty)
        XCTAssertNotNil(created.etag)
        let found = try await book.find(makoshID: id)
        XCTAssertEqual(found?.externalID, created.externalID)
        let changes = try await book.changes(cursor: nil)
        XCTAssertEqual(changes.cards.count, 1)
        XCTAssertEqual(changes.cards.first?.makoshID, id)
        XCTAssertEqual(changes.cards.first?.imported.displayName, "Иванов Пётр")
        XCTAssertEqual(changes.cards.first?.imported.phones, ["+7 916 000-00-00"])
        XCTAssertTrue(changes.full)
        let updated = try await book.update(externalID: created.externalID, etag: created.etag, card: card("Иванов П."))
        XCTAssertNotEqual(updated.etag, created.etag)
        let after = try await book.changes(cursor: changes.cursor)
        XCTAssertEqual(after.cards.map(\.imported.displayName), ["Иванов П."])
        XCTAssertFalse(after.full)
        try await book.delete(externalID: created.externalID, etag: updated.etag)
        let gone = try await book.changes(cursor: after.cursor)
        XCTAssertEqual(gone.removedExternalIDs, [created.externalID])
        let missing = try await book.find(makoshID: id)
        XCTAssertNil(missing)
        let writes = await book.writes
        XCTAssertEqual(writes.map { $0.split(separator: " ").first.map(String.init) }, ["create", "update", "delete"])
    }

    func testFailNextAppliesThenThrows() async throws {
        let book = PersonSyntheticBook()
        await book.failNext(.unknownOutcome(stage: "put"))
        do {
            _ = try await book.create(card())
            XCTFail("the first write after failNext must throw")
        } catch { XCTAssertEqual(error as? PersonsFailure, .unknownOutcome(stage: "put")) }
        let found = try await book.find(makoshID: id)
        XCTAssertNotNil(found, "the server applied the write before the connection dropped")
        let second = try await book.create(card())
        XCTAssertNotEqual(second.externalID, found?.externalID, "a plain second create makes a second card")
    }

    func testFailNextWithoutApplying() async throws {
        let book = PersonSyntheticBook()
        await book.failNext(.unknownOutcome(stage: "put"), applying: false)
        _ = try? await book.create(card())
        let found = try await book.find(makoshID: id)
        XCTAssertNil(found)
        let changes = try await book.changes(cursor: nil)
        XCTAssertTrue(changes.cards.isEmpty)
    }

    func testStaleEtagIsPreconditionFailed() async throws {
        let book = PersonSyntheticBook()
        let created = try await book.create(card())
        await book.editRemotely(externalID: created.externalID) { $0.phones = [] }
        do {
            _ = try await book.update(externalID: created.externalID, etag: created.etag, card: card())
            XCTFail("a changed card must refuse the old ETag")
        } catch { XCTAssertEqual(error as? PersonsFailure, .preconditionFailed) }
        let changes = try await book.changes(cursor: nil)
        XCTAssertEqual(changes.cards.first?.imported.phones, [])
        do {
            try await book.delete(externalID: created.externalID, etag: created.etag)
            XCTFail("delete with a stale ETag must refuse")
        } catch { XCTAssertEqual(error as? PersonsFailure, .preconditionFailed) }
        try await book.delete(externalID: created.externalID, etag: nil)
    }

    func testUnknownExternalIDIsNotFound() async throws {
        let book = PersonSyntheticBook()
        do {
            _ = try await book.update(externalID: "nope", etag: nil, card: card())
            XCTFail()
        } catch { XCTAssertEqual(error as? PersonsFailure, .notFound) }
        do {
            try await book.delete(externalID: "nope", etag: nil)
            XCTFail()
        } catch { XCTAssertEqual(error as? PersonsFailure, .notFound) }
    }

    func testSeededCardsAndRemoteRemoval() async throws {
        let seeded = RemoteCard(
            externalID: "c-1", etag: "e1", makoshID: nil,
            imported: ImportedPerson(externalID: "c-1", displayName: "Анна", emails: ["anna@x.ru"]), kind: .person)
        let book = PersonSyntheticBook(cards: [seeded])
        let changes = try await book.changes(cursor: nil)
        XCTAssertEqual(changes.cards, [seeded])
        await book.removeRemotely(externalID: "c-1")
        let after = try await book.changes(cursor: changes.cursor)
        XCTAssertEqual(after.removedExternalIDs, ["c-1"])
        let capabilities = await book.capabilities
        XCTAssertTrue(capabilities.acceptsOrganizations)
        XCTAssertFalse(capabilities.requiresPhoneOrPeer)
        XCTAssertTrue(capabilities.supportsMarker)
    }
}
