import Foundation
import XCTest

@testable import MakoshCore

final class PersonMembershipTests: XCTestCase {
    private var database: PostgresTestDatabase!
    private var store: PersonStore!
    override func setUpWithError() throws {
        database = try PostgresTestDatabase()
        store = try database.makeStore()
    }
    override func tearDownWithError() throws {
        store = nil
        try database?.cleanup()
    }

    func testManualMembershipIsConfirmedAtOnce() throws {
        let person = try store.createPerson(draft: .init(displayName: "Иванов"))
        let organization = try store.createOrganization(name: "ИП Сидоров")
        let membership = try XCTUnwrap(
            try store.suggestMembership(personID: person, organizationID: organization, role: "Менеджер", origin: .manual))
        XCTAssertEqual(membership.state, .confirmed)
        XCTAssertEqual(membership.role, "Менеджер")
        XCTAssertEqual(try store.members(of: organization).map(\.personID), [person])
        XCTAssertEqual(try store.memberships(of: person).map(\.organizationID), [organization])
        XCTAssertEqual(try store.person(id: organization)?.kind, .organization)
        XCTAssertEqual(try store.person(id: person)?.events.last?.kind, "membershipConfirmed")
    }

    func testSuggestedMembershipIsNotRepeatedAfterRemoval() throws {
        let person = try store.createPerson(draft: .init(displayName: "Иванов", emails: ["i@sidorov.ru"]))
        let organization = try store.createOrganization(name: "sidorov.ru")
        let membership = try XCTUnwrap(
            try store.suggestMembership(personID: person, organizationID: organization, role: "", origin: .emailDomain("sidorov.ru")))
        XCTAssertEqual(membership.state, .suggested)
        XCTAssertEqual(try store.person(id: person)?.events.last?.kind, "membershipSuggested")
        try store.setMembershipState(id: membership.id, state: .removed)
        XCTAssertNil(
            try store.suggestMembership(personID: person, organizationID: organization, role: "", origin: .emailDomain("sidorov.ru")))
        XCTAssertTrue(try store.members(of: organization).isEmpty)
        XCTAssertEqual(try store.members(of: organization, includingRemoved: true).map(\.state), [.removed])
        XCTAssertEqual(try store.person(id: person)?.events.last?.kind, "membershipRemoved")
    }

    func testSecondSuggestionForSamePairIsNil() throws {
        let person = try store.createPerson(draft: .init(displayName: "Иванов"))
        let organization = try store.createOrganization(name: "ИП Сидоров")
        XCTAssertNotNil(try store.suggestMembership(personID: person, organizationID: organization, role: "", origin: .manual))
        XCTAssertNil(try store.suggestMembership(personID: person, organizationID: organization, role: "", origin: .emailDomain("x.ru")))
    }

    func testMembershipRequiresOrganizationKind() throws {
        let person = try store.createPerson(draft: .init(displayName: "Иванов"))
        let other = try store.createPerson(draft: .init(displayName: "Петров"))
        XCTAssertThrowsError(try store.suggestMembership(personID: person, organizationID: other, role: "", origin: .manual)) { error in
            guard case StoreError.invalid = error else { return XCTFail("Expected invalid, got \(error)") }
        }
        let organization = try store.createOrganization(name: "ИП Сидоров")
        XCTAssertThrowsError(try store.suggestMembership(personID: organization, organizationID: organization, role: "", origin: .manual))
    }

    func testPersonMayBelongToTwoOrganizations() throws {
        let person = try store.createPerson(draft: .init(displayName: "Иванов"))
        let a = try store.createOrganization(name: "A")
        let b = try store.createOrganization(name: "B")
        _ = try store.suggestMembership(personID: person, organizationID: a, role: "", origin: .manual)
        _ = try store.suggestMembership(
            personID: person, organizationID: b, role: "", origin: .companyField(.init(service: "mail", accountID: "m")))
        XCTAssertEqual(Set(try store.memberships(of: person).map(\.organizationID)), [a, b])
        XCTAssertEqual(try store.organizations().map(\.displayName), ["A", "B"])
    }

    func testIllegalStateMoveIsRefused() throws {
        let person = try store.createPerson(draft: .init(displayName: "Иванов"))
        let organization = try store.createOrganization(name: "A")
        let membership = try XCTUnwrap(
            try store.suggestMembership(personID: person, organizationID: organization, role: "", origin: .manual))
        XCTAssertThrowsError(try store.setMembershipState(id: membership.id, state: .suggested))
        try store.setMembershipState(id: membership.id, state: .removed)
        try store.setMembershipState(id: membership.id, state: .confirmed)
        XCTAssertEqual(try store.memberships(of: person).first?.state, .confirmed)
        try store.setMembershipRole(id: membership.id, role: "Директор")
        XCTAssertEqual(try store.memberships(of: person).first?.role, "Директор")
    }

    func testOrganizationLookupIgnoresCaseAndSpaces() throws {
        let organization = try store.createOrganization(name: "ИП Сидоров")
        XCTAssertEqual(try store.organization(named: " ип сидоров ")?.id, organization)
        XCTAssertNil(try store.organization(named: "ООО Ромашка"))
    }
}
