import Foundation
import XCTest

@testable import MakoshCore

final class PersonReconciliationTests: XCTestCase {
    private var database: PostgresTestDatabase!
    private var store: PersonStore!
    private let source = ImportSource(service: "telegram", accountID: "acc")
    private let book = ImportSource(service: "google-contacts", accountID: "subject")
    override func setUpWithError() throws {
        database = try PostgresTestDatabase()
        store = try database.makeStore()
    }
    override func tearDownWithError() throws {
        store = nil
        try database?.cleanup()
    }
    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func imported(phones: [String] = [], name: String = "A") -> ImportedPerson {
        ImportedPerson(externalID: "x", displayName: name, phones: phones)
    }

    func testImportAddsToManuallyEditedListInsteadOfBeingBlocked() throws {
        let id = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 1"]))
        _ = try store.linkImportedPerson(imported(phones: ["+7 2"]), source: source, fetchedAt: date(100), contactID: id)
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.phones, ["+7 1", "+7 2"])
        XCTAssertEqual(person.manualValues, [ManualValue(field: "phones", value: "+7 1")])
        XCTAssertFalse(person.manualFields.contains("phones"))
    }

    func testRemovedValueIsNotReturnedBySource() throws {
        let id = try store.linkImportedPerson(imported(phones: ["+7 2"]), source: source, fetchedAt: date(100), contactID: nil)
        try store.removeValue(personID: id, field: .phones, value: "+7 2", reason: .removedByUser)
        _ = try store.linkImportedPerson(imported(phones: ["+7 2"]), source: source, fetchedAt: date(200), contactID: id)
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.phones, [])
        XCTAssertEqual(person.former.map(\.value), ["+7 2"])
        XCTAssertEqual(person.former.first?.reason, .removedByUser)
        let observation = try XCTUnwrap(person.observations.first { $0.field == "phones" && $0.value == "+7 2" })
        XCTAssertEqual(observation.source.fetchedAt, date(200))
        XCTAssertEqual(person.events.filter { $0.kind == "valueRemoved" }.count, 1)
    }

    func testRemovedInBookKeepsHistoryAndDropsCurrent() throws {
        let id = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 1", "+7 2"]))
        try store.removeValue(personID: id, field: .phones, value: "+7 2", reason: .removedInBook(book))
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.phones, ["+7 1"])
        XCTAssertEqual(person.former.first?.reason, .removedInBook(book))
        XCTAssertFalse(person.manualValues.contains(ManualValue(field: "phones", value: "+7 2")))
        // Removing an already former value changes nothing.
        let revision = person.revision
        try store.removeValue(personID: id, field: .phones, value: "+7 2", reason: .removedByUser)
        XCTAssertEqual(try store.person(id: id)?.revision, revision)
    }

    func testRestoreValueMakesItManual() throws {
        let id = try store.linkImportedPerson(imported(phones: ["+7 2"]), source: source, fetchedAt: date(100), contactID: nil)
        try store.removeValue(personID: id, field: .phones, value: "+7 2", reason: .removedByUser)
        try store.restoreValue(personID: id, field: .phones, value: "+7 2")
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.phones, ["+7 2"])
        XCTAssertTrue(person.former.isEmpty)
        XCTAssertTrue(person.manualValues.contains(ManualValue(field: "phones", value: "+7 2")))
        XCTAssertEqual(person.events.last?.kind, "valueRestored")
    }

    func testDraftRemovingAValueRecordsFormer() throws {
        let id = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 1", "+7 2"], emails: ["a@x"]))
        try store.updatePerson(id: id, draft: .init(displayName: "A", phones: ["+7 1", "+7 3"], emails: ["a@x"]))
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.phones, ["+7 1", "+7 3"])
        XCTAssertEqual(person.former.map(\.value), ["+7 2"])
        XCTAssertEqual(person.former.first?.reason, .removedByUser)
        XCTAssertEqual(
            Set(person.manualValues.filter { $0.field == "phones" }),
            [ManualValue(field: "phones", value: "+7 1"), ManualValue(field: "phones", value: "+7 3")])
        XCTAssertFalse(person.manualFields.contains("phones"))
        XCTAssertTrue(person.manualFields.contains("displayName"))
    }

    func testScalarManualFieldsStillBlockImports() throws {
        let id = try store.createPerson(draft: .init(displayName: "Manual", givenName: "M", familyName: "N"))
        _ = try store.linkImportedPerson(
            ImportedPerson(externalID: "x", displayName: "Imported", givenName: "I", familyName: "J", jobTitle: "Boss"),
            source: source, fetchedAt: date(100), contactID: id)
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.displayName, "Manual")
        XCTAssertEqual(person.givenName, "M")
        XCTAssertEqual(person.familyName, "N")
        XCTAssertEqual(person.jobTitle, "Boss")
        XCTAssertTrue(person.observations.contains { $0.field == "displayName" && $0.value == "Imported" })
        XCTAssertTrue(person.observations.contains { $0.field == "givenName" && $0.value == "I" })
    }

    func testImportFillsStructuredNameWhenNotManual() throws {
        let id = try store.linkImportedPerson(
            ImportedPerson(externalID: "x", displayName: "Иванов Пётр", givenName: "Пётр", familyName: "Иванов", usernames: ["ivanov"]),
            source: source, fetchedAt: date(100), contactID: nil)
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.givenName, "Пётр")
        XCTAssertEqual(person.familyName, "Иванов")
        XCTAssertEqual(person.usernames, ["ivanov"])
    }

    func testProposedObservationIsNotCurrentUntilConfirmed() throws {
        let id = try store.createPerson(draft: .init(displayName: "A"))
        var person = try XCTUnwrap(try store.person(id: id))
        let proposed = Observation(
            field: "emails", value: "p@x", source: SourceStamp(identity: .init(service: "ai", accountID: "local", externalID: "1")),
            status: .proposed)
        let rejected = Observation(
            field: "phones", value: "+7 9", source: SourceStamp(identity: .init(service: "ai", accountID: "local", externalID: "2")),
            status: .proposed)
        person.observations += [proposed, rejected]
        try store.repositoryForTests.write { try store.repositoryForTests.update(person) }
        XCTAssertEqual(try store.person(id: id)?.emails, [])
        try store.setObservationStatus(personID: id, observationID: proposed.id, status: .confirmed)
        let confirmed = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(confirmed.emails, ["p@x"])
        XCTAssertEqual(confirmed.observations.first { $0.id == proposed.id }?.status, .confirmed)
        XCTAssertThrowsError(try store.setObservationStatus(personID: id, observationID: proposed.id, status: .observed))
        try store.rejectProposedObservation(personID: id, observationID: rejected.id)
        let after = try XCTUnwrap(try store.person(id: id))
        XCTAssertFalse(after.observations.contains { $0.id == rejected.id })
        XCTAssertEqual(after.phones, [])
    }
}
