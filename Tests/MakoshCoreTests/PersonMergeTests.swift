import Foundation
import XCTest

@testable import MakoshCore

final class PersonMergeTests: XCTestCase {
    private var database: PostgresTestDatabase!
    private var store: PersonStore!
    private let mail = ImportSource(service: "mail", accountID: "m")
    private let telegram = ImportSource(service: "telegram", accountID: "t")
    override func setUpWithError() throws {
        database = try PostgresTestDatabase()
        store = try database.makeStore()
    }
    override func tearDownWithError() throws {
        store = nil
        try database?.cleanup()
    }
    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }

    func testMergeRefusesDifferentKinds() throws {
        let person = try store.createPerson(draft: .init(displayName: "Иванов"))
        let organization = try store.createOrganization(name: "ИП Сидоров")
        XCTAssertThrowsError(try store.merge(survivorID: person, removedID: organization)) { error in
            guard case StoreError.invalid = error else { return XCTFail("Expected invalid, got \(error)") }
        }
        XCTAssertNotNil(try store.person(id: organization))
    }

    func testMergeUnionsFormerManualValuesAndFlag() throws {
        let survivor = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 1"]))
        let removed = try store.createPerson(draft: .init(displayName: "B", phones: ["+7 2", "+7 3"]))
        try store.removeValue(personID: removed, field: .phones, value: "+7 3", reason: .removedByUser)
        try store.setAddressBook(personID: removed, true, origin: .user)
        _ = try store.merge(survivorID: survivor, removedID: removed)
        let merged = try XCTUnwrap(try store.person(id: survivor))
        XCTAssertTrue(merged.addressBook)
        XCTAssertEqual(merged.addressBookOrigin, .user)
        XCTAssertEqual(merged.phones, ["+7 1", "+7 2"])
        XCTAssertEqual(merged.former.map(\.value), ["+7 3"])
        XCTAssertEqual(
            Set(merged.manualValues.filter { $0.field == "phones" }),
            [ManualValue(field: "phones", value: "+7 1"), ManualValue(field: "phones", value: "+7 2")])
        XCTAssertNil(try store.person(id: removed))
    }

    func testMergeMovesMembershipsToSurvivor() throws {
        let survivor = try store.createPerson(draft: .init(displayName: "A"))
        let removed = try store.createPerson(draft: .init(displayName: "B"))
        let organization = try store.createOrganization(name: "ИП Сидоров")
        _ = try store.suggestMembership(personID: removed, organizationID: organization, role: "Менеджер", origin: .manual)
        _ = try store.merge(survivorID: survivor, removedID: removed)
        XCTAssertEqual(try store.members(of: organization).map(\.personID), [survivor])
        XCTAssertEqual(try store.memberships(of: survivor).map(\.role), ["Менеджер"])
    }

    func testMergeOfOrganizationsMovesMembers() throws {
        let a = try store.createOrganization(name: "A")
        let b = try store.createOrganization(name: "B")
        let person = try store.createPerson(draft: .init(displayName: "Иванов"))
        _ = try store.suggestMembership(personID: person, organizationID: b, role: "", origin: .manual)
        _ = try store.merge(survivorID: a, removedID: b)
        XCTAssertEqual(try store.members(of: a).map(\.personID), [person])
        XCTAssertEqual(try store.memberships(of: person).map(\.organizationID), [a])
    }

    func testDetachAfterEditMovesSourceAndRecordsNoMerge() throws {
        let id = try store.linkImportedPerson(
            .init(externalID: "a@x", displayName: "Иванов", emails: ["a@x"]), source: mail, fetchedAt: date(100), contactID: nil)
        let telegramIdentity = ServiceIdentity(service: "telegram", accountID: "t", externalID: "42")
        _ = try store.linkImportedPerson(
            .init(externalID: "42", displayName: "Иванов TG", phones: ["+7 tg"]), source: telegram, fetchedAt: date(100), contactID: id)
        var draft = try XCTUnwrap(try store.person(id: id)).draft
        draft.displayName = "Иванов Пётр"
        draft.phones.append("+7 manual")
        try store.updatePerson(id: id, draft: draft)
        let newID = try store.detachIdentity(personID: id, identity: telegramIdentity)
        let detached = try XCTUnwrap(try store.person(id: newID))
        let original = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(detached.identities, [telegramIdentity])
        XCTAssertEqual(detached.displayName, "Иванов TG")
        XCTAssertEqual(detached.phones, ["+7 tg"])
        XCTAssertTrue(detached.observations.allSatisfy { $0.source.identity == telegramIdentity })
        XCTAssertFalse(original.identities.contains(telegramIdentity))
        XCTAssertEqual(original.phones, ["+7 manual"])
        XCTAssertEqual(original.displayName, "Иванов Пётр")
        XCTAssertFalse(original.observations.contains { $0.source.identity == telegramIdentity })
        XCTAssertTrue(try store.noMergePairs().contains(NoMergePair(id, newID)))
        XCTAssertEqual(original.events.last?.kind, "identityDetached")
        XCTAssertEqual(detached.events.last?.kind, "identityDetached")
    }

    func testDetachRefusesTheOnlySource() throws {
        let id = try store.linkImportedPerson(
            .init(externalID: "a@x", displayName: "Иванов", emails: ["a@x"]), source: mail, fetchedAt: date(100), contactID: nil)
        let identity = ServiceIdentity(service: "mail", accountID: "m", externalID: "a@x")
        XCTAssertThrowsError(try store.detachIdentity(personID: id, identity: identity)) { error in
            guard case StoreError.invalid = error else { return XCTFail("Expected invalid, got \(error)") }
        }
        XCTAssertEqual(try store.persons().count, 1)
    }

    func testDetachKeepsNotesOfOtherSources() throws {
        let id = try store.linkImportedPerson(
            .init(externalID: "a@x", displayName: "Иванов", emails: ["a@x"], notes: ["mail note"]), source: mail, fetchedAt: date(100),
            contactID: nil)
        let telegramIdentity = ServiceIdentity(service: "telegram", accountID: "t", externalID: "42")
        _ = try store.linkImportedPerson(
            .init(externalID: "42", displayName: "TG", notes: ["tg note"]), source: telegram, fetchedAt: date(100), contactID: id)
        let newID = try store.detachIdentity(personID: id, identity: telegramIdentity)
        XCTAssertEqual(try store.person(id: id)?.notes.map(\.text), ["mail note"])
        XCTAssertEqual(try store.person(id: newID)?.notes.map(\.text), ["tg note"])
    }

    func testUndoMergeStillRequiresUnchangedRevision() throws {
        let a = try store.createPerson(draft: .init(displayName: "A"))
        let b = try store.createPerson(draft: .init(displayName: "B"))
        let mergeID = try store.merge(survivorID: a, removedID: b)
        try store.addNote(contactID: a, text: "later")
        XCTAssertThrowsError(try store.undoMerge(id: mergeID)) { error in
            guard case StoreError.undoConflict = error else { return XCTFail("Expected undoConflict, got \(error)") }
        }
        XCTAssertNil(try store.person(id: b))
    }
}
