import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshPersons

@MainActor
final class PersonsWorkspaceModelTests: XCTestCase {
    private var db: PersonsTestDatabase!
    private var persons: PersonStore!
    private var store: PersonsStore!
    private var books: SyntheticBooks!
    private var service: PersonsService!
    private var worker: PersonWorkspaceWorker!

    override func setUp() async throws {
        db = try personsDatabase()
        persons = try db.persons()
        store = try await personsStore(db)
        books = SyntheticBooks()
        service = PersonsService(
            persons: persons, store: store, vault: PersonsCredentialVault(access: .memory()), adapterFactory: books.factory, google: nil,
            grants: GoogleGrantVault(access: .memory()))
        try await service.open()
        worker = PersonWorkspaceWorker(configuration: .init(connectionString: db.connectionString, schema: db.schema))
        _ = try await worker.open()
    }

    func testLoadBuildsTreeFromWorkerAndService() async throws {
        let organization = try persons.createOrganization(name: "ИП Сидоров")
        let ivanov = try persons.createPerson(draft: .init(displayName: "Иванов", phones: ["+7 916 000-00-00"]))
        _ = try persons.suggestMembership(personID: ivanov, organizationID: organization, role: "Менеджер", origin: .manual)
        _ = try persons.createPerson(draft: .init(displayName: "Анна"))
        let model = PersonsWorkspaceModel(service: service, persons: worker)
        await model.load()
        XCTAssertNotNil(model.snapshot)
        XCTAssertEqual(model.tree.count, 2)
        guard case .organization(let id, let count) = model.tree[0].kind else { return XCTFail() }
        XCTAssertEqual(id, organization)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(model.tree[0].children.isEmpty, "organizations start collapsed")
        model.toggleExpanded(organizationID: organization)
        XCTAssertEqual(model.tree[0].children.map(\.title), ["Иванов"])
        model.setSearch("анн")
        await model.refresh()
        XCTAssertEqual(model.tree.flatMap(\.children).map(\.title), ["Анна"])
        XCTAssertEqual(model.tree.count, 1)
    }

    func testBookStatesJoinEntriesAttemptsAndBlocked() async throws {
        let synthetic = PersonBook(kind: .synthetic, name: "Google", accountID: "g")
        try await store.saveBook(synthetic)
        let book = books.add("g")
        let telegram = PersonBook(kind: .telegram, name: "Telegram", accountID: "100")
        try await store.saveBook(telegram)
        _ = books.add(
            "100", PersonSyntheticBook(capabilities: .init(acceptsOrganizations: false, requiresPhoneOrPeer: true, supportsMarker: false)))
        let person = try persons.createPerson(draft: .init(displayName: "Анна", emails: ["anna@x.ru"]))
        try persons.setAddressBook(personID: person, true, origin: .user)
        await book.failNext(.unknownOutcome(stage: "put"))
        _ = await service.writePass()
        let model = PersonsWorkspaceModel(service: service, persons: worker)
        await model.load()
        let states = model.bookStates(for: person)
        XCTAssertEqual(states.count, 2)
        let google = try XCTUnwrap(states.first { $0.book.id == synthetic.id })
        XCTAssertEqual(google.attempt?.state, .unknown)
        XCTAssertNil(google.entry)
        XCTAssertNil(google.blocked)
        let tg = try XCTUnwrap(states.first { $0.book.id == telegram.id })
        XCTAssertEqual(tg.blocked, .noPhoneOrPeer)
        XCTAssertEqual(model.filter, .all)
        model.setFilter(.notSynced)
        await model.refresh()
        XCTAssertEqual(model.tree.flatMap(\.children).map(\.title), ["Анна"])
        await model.settle(bookID: synthetic.id)
        let after = model.bookStates(for: person).first { $0.book.id == synthetic.id }
        XCTAssertEqual(after?.entry?.state, .managed)
        XCTAssertNil(after?.attempt)
    }

    func testFlagDeleteEverywhereAndMailCount() async throws {
        let synthetic = PersonBook(kind: .synthetic, name: "Google", accountID: "g")
        try await store.saveBook(synthetic)
        let book = books.add("g")
        let person = try persons.createPerson(draft: .init(displayName: "Анна", emails: ["anna@x.ru"]))
        _ = try persons.recordMailEvidence(accountID: "m", address: "anna@x.ru", spam: false)
        _ = try persons.recordMailEvidence(accountID: "m", address: "anna@x.ru", spam: false)
        let model = PersonsWorkspaceModel(service: service, persons: worker)
        await model.load()
        let count = await model.mailCount(address: "Anna@x.ru")
        XCTAssertEqual(count, 2)
        await model.setAddressBook(personID: person, on: true)
        await service.settled()
        let card = await book.card(for: person)
        XCTAssertNotNil(card)
        await model.deleteEverywhere(personID: person)
        let gone = await book.card(for: person)
        XCTAssertNil(gone)
        XCTAssertNil(model.error)
    }
}
