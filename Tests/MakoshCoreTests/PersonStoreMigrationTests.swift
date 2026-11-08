import Foundation
import XCTest

@testable import MakoshCore

final class PersonStoreMigrationTests: XCTestCase {
    private var database: PostgresTestDatabase!
    override func setUpWithError() throws { database = try PostgresTestDatabase() }
    override func tearDownWithError() throws { try database?.cleanup() }

    private func insertV2(_ id: UUID, manualFields: [String], phones: [String]) throws {
        let payload = String(decoding: PersonFixture.contactV2JSON(id: id, manualFields: manualFields, phones: phones), as: UTF8.self)
        try database.execute("INSERT INTO contact_records (id, payload) VALUES ('\(id.uuidString)', '\(payload)')")
    }

    func testOpeningVersionTwoUpgradesManualListsAndVersion() throws {
        let id = UUID(), plain = UUID()
        try database.execute("UPDATE contact_store_meta SET schema_version=2 WHERE id=1")
        try insertV2(id, manualFields: ["phones", "displayName"], phones: ["+7 1", "+7 2"])
        try insertV2(plain, manualFields: [], phones: ["+7 3"])
        let store = try database.makeStore()
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.manualValues, [ManualValue(field: "phones", value: "+7 1"), ManualValue(field: "phones", value: "+7 2")])
        XCTAssertEqual(person.manualFields, ["displayName"])
        XCTAssertEqual(person.kind, .person)
        XCTAssertFalse(person.addressBook)
        XCTAssertEqual(try store.person(id: plain)?.manualValues, [])
        XCTAssertEqual(try database.execute("SELECT schema_version::text FROM contact_store_meta WHERE id=1"), [["3"]])
        let before = try database.contactStoreSnapshot()
        _ = try database.makeStore()
        XCTAssertEqual(try database.contactStoreSnapshot(), before)
    }

    func testVersionOneIsRefused() throws {
        try database.execute("UPDATE contact_store_meta SET schema_version=1 WHERE id=1")
        XCTAssertThrowsError(try database.makeStore()) { error in
            guard case StoreError.unsupportedSchema(1) = error else { return XCTFail("Expected unsupportedSchema(1), got \(error)") }
        }
        XCTAssertEqual(try database.execute("SELECT schema_version::text FROM contact_store_meta WHERE id=1"), [["1"]])
    }

    func testPersonsHidesInactiveButAllPersonsShowsThem() throws {
        let store = try database.makeStore()
        let live = try store.createPerson(draft: PersonDraft(displayName: "Live"))
        let gone = try store.createPerson(draft: PersonDraft(displayName: "Gone"))
        var person = try XCTUnwrap(try store.person(id: gone))
        person.deletedAt = Date()
        try store.repositoryForTests.write { try store.repositoryForTests.update(person) }
        XCTAssertEqual(try store.persons().map(\.id), [live])
        XCTAssertEqual(Set(try store.allPersons(includingInactive: true).map(\.id)), [live, gone])
        XCTAssertEqual(try store.allPersons(includingInactive: false).map(\.id), [live])
    }

    func testSummariesMatchAcrossFields() throws {
        let store = try database.makeStore()
        _ = try store.createPerson(
            draft: PersonDraft(displayName: "Иванов Пётр", organization: "ИП Сидоров", jobTitle: "Менеджер", emails: ["ivanov@sidorov.ru"]))
        _ = try store.createPerson(draft: PersonDraft(displayName: "Анна", phones: ["+7 916 000-00-00"], usernames: ["anna_k"]))
        _ = try store.createPerson(draft: PersonDraft(displayName: "Борис"))
        XCTAssertEqual(try store.summaries(matching: "sidorov", limit: 10).map(\.displayName), ["Иванов Пётр"])
        XCTAssertEqual(try store.summaries(matching: "менедж", limit: 10).map(\.displayName), ["Иванов Пётр"])
        XCTAssertEqual(try store.summaries(matching: "anna_k", limit: 10).map(\.displayName), ["Анна"])
        XCTAssertEqual(try store.summaries(matching: "916", limit: 10).map(\.displayName), ["Анна"])
        XCTAssertEqual(try store.summaries(matching: "", limit: 10).map(\.displayName), ["Анна", "Борис", "Иванов Пётр"])
        XCTAssertEqual(try store.summaries(matching: "", limit: 2).count, 2)
        XCTAssertEqual(try store.summaries(matching: "", limit: 10).first?.firstPhone, "+7 916 000-00-00")
    }
}
