import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class PersonsTreeTests: XCTestCase {
    private func summary(_ name: String, kind: PersonKind = .person, flagged: Bool = false) -> PersonSummary {
        PersonSummary(
            id: UUID(), kind: kind, displayName: name, organization: "", jobTitle: "", firstEmail: nil, firstPhone: nil,
            addressBook: flagged,
            isActive: true, revision: 1)
    }
    private func membership(_ person: PersonSummary, _ organization: PersonSummary, state: MembershipState = .confirmed) -> PersonMembership
    {
        PersonMembership(organizationID: organization.id, personID: person.id, role: "", origin: .manual, state: state)
    }

    func testTreeGroupsByOrganizationAndLeavesRest() {
        let ivanov = summary("Иванов"), anna = summary("Анна"), boris = summary("Борис")
        let sidorov = summary("ИП Сидоров", kind: .organization)
        let tree = PersonsTree.build(
            summaries: [ivanov, anna, boris], organizations: [sidorov], memberships: [membership(ivanov, sidorov)], expanded: [sidorov.id],
            filter: .all, blocked: [], suggestedPersonIDs: [])
        XCTAssertEqual(tree.count, 2)
        guard case .organization(let id, let count) = tree[0].kind else { return XCTFail("first node is the organization") }
        XCTAssertEqual(id, sidorov.id)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(tree[0].children.map(\.title), ["Иванов"])
        guard case .section(let title) = tree[1].kind else { return XCTFail("last node is the section") }
        XCTAssertEqual(title, "Без организации")
        XCTAssertEqual(tree[1].children.map(\.title), ["Анна", "Борис"])
    }

    func testCollapsedOrganizationHasNoChildrenButKeepsCount() {
        let ivanov = summary("Иванов")
        let sidorov = summary("ИП Сидоров", kind: .organization)
        let tree = PersonsTree.build(
            summaries: [ivanov], organizations: [sidorov], memberships: [membership(ivanov, sidorov)], expanded: [], filter: .all,
            blocked: [],
            suggestedPersonIDs: [])
        XCTAssertTrue(tree[0].children.isEmpty)
        guard case .organization(_, let count) = tree[0].kind else { return XCTFail() }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(tree.count, 1, "an empty «Без организации» section is not shown")
    }

    func testPersonInTwoOrganizationsAppearsTwice() {
        let ivanov = summary("Иванов")
        let a = summary("A", kind: .organization), b = summary("B", kind: .organization)
        let tree = PersonsTree.build(
            summaries: [ivanov], organizations: [a, b], memberships: [membership(ivanov, a), membership(ivanov, b, state: .suggested)],
            expanded: [a.id, b.id], filter: .all, blocked: [], suggestedPersonIDs: [ivanov.id])
        XCTAssertEqual(tree.map(\.children.count), [1, 1])
        XCTAssertNotEqual(tree[0].children[0].id, tree[1].children[0].id, "node ids are unique per place")
        XCTAssertTrue(tree[1].children[0].suggested)
        XCTAssertFalse(tree[0].children[0].suggested)
    }

    func testAddressBookFilterKeepsOrganizationsWithFlaggedMembersOnly() {
        let flagged = summary("Иванов", flagged: true), plain = summary("Пётр")
        let a = summary("A", kind: .organization), b = summary("B", kind: .organization)
        let tree = PersonsTree.build(
            summaries: [flagged, plain], organizations: [a, b], memberships: [membership(flagged, a), membership(plain, b)],
            expanded: [a.id, b.id],
            filter: .addressBook, blocked: [], suggestedPersonIDs: [])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].children.map(\.title), ["Иванов"])
    }

    func testNotSyncedFilterUsesBlocked() {
        let blocked = summary("Анна", flagged: true), fine = summary("Борис", flagged: true)
        let tree = PersonsTree.build(
            summaries: [blocked, fine], organizations: [], memberships: [], expanded: [], filter: .notSynced, blocked: [blocked.id],
            suggestedPersonIDs: [])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].children.map(\.title), ["Анна"])
        XCTAssertTrue(tree[0].children[0].blocked)
    }

    func testRemovedMembershipsDoNotPlacePersons() {
        let ivanov = summary("Иванов")
        let a = summary("A", kind: .organization)
        let tree = PersonsTree.build(
            summaries: [ivanov], organizations: [a], memberships: [membership(ivanov, a, state: .removed)], expanded: [a.id], filter: .all,
            blocked: [], suggestedPersonIDs: [])
        guard case .organization(_, let count) = tree[0].kind else { return XCTFail() }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(tree[1].children.map(\.title), ["Иванов"])
    }
}
