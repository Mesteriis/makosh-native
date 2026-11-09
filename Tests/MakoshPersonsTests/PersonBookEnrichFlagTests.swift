import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshPersons

final class PersonBookEnrichFlagTests: XCTestCase {
    func testFlagDefaultsFalseAndDecodesOldJSON() throws {
        let book = PersonBook(kind: .carddav, name: "Яндекс", accountID: "acc")
        XCTAssertFalse(book.enrichAutomatically)
        let flagged = PersonBook(kind: .carddav, name: "Яндекс", accountID: "acc", enrichAutomatically: true)
        XCTAssertTrue(flagged.enrichAutomatically)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(flagged)) as! [String: Any]
        json.removeValue(forKey: "enrichAutomatically")
        let decoded = try JSONDecoder().decode(PersonBook.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.enrichAutomatically, "rows written before the flag existed read as off")
    }

    func testChannelBooksNeverCarryFlag() {
        for kind in [PersonBookKind.mail, .whatsapp, .teams] {
            XCTAssertFalse(PersonBook(kind: kind, name: "k", accountID: "a", enrichAutomatically: true).enrichAutomatically, "\(kind)")
        }
        XCTAssertTrue(PersonBook(kind: .telegram, name: "t", accountID: "a", enrichAutomatically: true).enrichAutomatically)
    }

    func testSetBookOptionsPersistsFlag() async throws {
        let db = try personsDatabase()
        let store = try await personsStore(db)
        let persons = try db.persons()
        let service = PersonsService(
            persons: persons, store: store, vault: PersonsCredentialVault(access: .memory()),
            adapterFactory: { _, _ in throw PersonsFailure.notFound },
            google: nil, grants: GoogleGrantVault(access: .memory()))
        try await service.open()
        let book = try await service.connectSynthetic(name: "S", accountID: "s")
        try await service.setBookOptions(
            id: book.id, readBook: nil, isAddressBookSource: nil, acceptsAddressBook: nil, collectConversations: nil,
            enrichAutomatically: true)
        let saved = try await store.book(id: book.id)
        XCTAssertEqual(saved?.enrichAutomatically, true)
        try await service.setBookOptions(
            id: book.id, readBook: nil, isAddressBookSource: nil, acceptsAddressBook: nil, collectConversations: nil,
            enrichAutomatically: false)
        let cleared = try await store.book(id: book.id)
        XCTAssertEqual(cleared?.enrichAutomatically, false)
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.books.first?.enrichAutomatically, false)
        await service.close()
    }
}
