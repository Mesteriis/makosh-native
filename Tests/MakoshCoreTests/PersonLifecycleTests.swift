import Foundation
import XCTest

@testable import MakoshCore

final class PersonLifecycleTests: XCTestCase {
    private var database: PostgresTestDatabase!
    private var store: PersonStore!
    private let mail = ImportSource(service: "mail", accountID: "m")
    private let google = ImportSource(service: "google-contacts", accountID: "subject")
    override func setUpWithError() throws {
        database = try PostgresTestDatabase()
        store = try database.makeStore()
    }
    override func tearDownWithError() throws {
        store = nil
        try database?.cleanup()
    }
    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func valueRows(_ id: UUID) throws -> [[String]] {
        try database.execute("SELECT field FROM person_values WHERE person_id='\(id.uuidString)' ORDER BY 1")
    }

    func testDeletedPersonKeepsIdentityAndAbsorbsNewObservations() throws {
        let id = try store.linkImportedPerson(
            .init(externalID: "a@x", displayName: "A", emails: ["a@x"]), source: mail, fetchedAt: date(100), contactID: nil)
        try store.deletePerson(id: id)
        let owner = try store.linkImportedPerson(
            .init(externalID: "a@x", displayName: "A", phones: ["+7 916 000-00-00"], emails: ["a@x"]), source: mail, fetchedAt: date(200),
            contactID: nil)
        XCTAssertEqual(owner, id)
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertNotNil(person.deletedAt)
        XCTAssertEqual(person.phones, ["+7 916 000-00-00"])
        XCTAssertFalse(try store.persons().contains { $0.id == id })
        XCTAssertEqual(person.events.filter { $0.kind == "deleted" }.count, 1)
    }

    func testDeletedPersonHasNoValueRowsAndNoAutoMerge() throws {
        let id = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 916 000-00-00"]))
        try store.deletePerson(id: id)
        XCTAssertTrue(try valueRows(id).isEmpty)
        let other = try store.createPerson(draft: .init(displayName: "B", phones: ["+7 916 000-00-00"]))
        XCTAssertNil(try store.autoMergeCandidate(for: other))
        XCTAssertNil(try store.autoMergeCandidate(for: id))
    }

    func testRestoreBringsValuesBack() throws {
        let id = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 916 000-00-00"]))
        try store.deletePerson(id: id)
        try store.restorePerson(id: id)
        XCTAssertEqual(try valueRows(id), [["phones"]])
        XCTAssertNil(try store.person(id: id)?.deletedAt)
        XCTAssertEqual(try store.person(id: id)?.events.last?.kind, "restored")
    }

    func testHidingAsSpamRemovesSuggestedMembershipsAndBlocksFlag() throws {
        let person = try store.createPerson(draft: .init(displayName: "S", emails: ["s@evil.test"]))
        let organization = try store.createOrganization(name: "evil.test")
        let membership = try XCTUnwrap(
            try store.suggestMembership(personID: person, organizationID: organization, role: "", origin: .emailDomain("evil.test")))
        try store.setHiddenAsSpam(id: person, true)
        XCTAssertEqual(try store.memberships(of: person, includingRemoved: true).first { $0.id == membership.id }?.state, .removed)
        XCTAssertTrue(try store.members(of: organization).isEmpty)
        XCTAssertThrowsError(try store.setAddressBook(personID: person, true, origin: .user))
        XCTAssertTrue(try valueRows(person).isEmpty)
        XCTAssertFalse(try store.persons().contains { $0.id == person })
        try store.setHiddenAsSpam(id: person, false)
        XCTAssertEqual(try valueRows(person), [["emails"]])
        XCTAssertEqual(try store.person(id: person)?.events.last?.kind, "unhidden")
    }

    func testMailEvidenceCountsPerAccountAndSumsAcross() throws {
        XCTAssertEqual(try store.recordMailEvidence(accountID: "a", address: "X@y", spam: false).clean, 1)
        XCTAssertEqual(try store.recordMailEvidence(accountID: "a", address: "x@y", spam: false).clean, 2)
        XCTAssertEqual(try store.recordMailEvidence(accountID: "b", address: "x@y", spam: true).spam, 1)
        let total = try store.mailEvidence(address: "x@y")
        XCTAssertEqual(total.clean, 2)
        XCTAssertEqual(total.spam, 1)
        XCTAssertEqual(try store.mailEvidence(address: "nobody@y").clean, 0)
    }

    func testUserFlagOutlivesSourceFlag() throws {
        let id = try store.createPerson(draft: .init(displayName: "A"))
        try store.setAddressBook(personID: id, true, origin: .sourceAccount(google))
        XCTAssertEqual(try store.person(id: id)?.addressBookOrigin, .sourceAccount(google))
        try store.setAddressBook(personID: id, true, origin: .user)
        XCTAssertEqual(try store.person(id: id)?.addressBookOrigin, .user)
        XCTAssertEqual(try store.clearAddressBook(fromSource: google), [])
        XCTAssertTrue(try XCTUnwrap(try store.person(id: id)).addressBook)
        let other = try store.createPerson(draft: .init(displayName: "B"))
        try store.setAddressBook(personID: other, true, origin: .sourceAccount(google))
        XCTAssertEqual(try store.clearAddressBook(fromSource: google), [other])
        XCTAssertFalse(try XCTUnwrap(try store.person(id: other)).addressBook)
        XCTAssertNil(try store.person(id: other)?.addressBookOrigin)
    }

    func testSourceFlagDoesNotDowngradeUserFlag() throws {
        let id = try store.createPerson(draft: .init(displayName: "A"))
        try store.setAddressBook(personID: id, true, origin: .user)
        let revision = try XCTUnwrap(try store.person(id: id)).revision
        try store.setAddressBook(personID: id, true, origin: .sourceAccount(google))
        XCTAssertEqual(try store.person(id: id)?.addressBookOrigin, .user)
        XCTAssertEqual(try store.person(id: id)?.revision, revision, "Nothing changed, nothing written")
        try store.setAddressBook(personID: id, false, origin: .user)
        XCTAssertFalse(try XCTUnwrap(try store.person(id: id)).addressBook)
    }
}
