import CPostgres
import Foundation
import MakoshPersons
import XCTest

@testable import MakoshApp
@testable import MakoshCore

@MainActor
final class PersonsSidebarTests: XCTestCase {
    func testDestinationTitleIsPersons() {
        XCTAssertEqual(WorkspaceDestination.persons.rawValue, "Персоны")
        XCTAssertEqual(WorkspaceDestination.persons.symbol, "person.2")
        XCTAssertFalse(WorkspaceDestination.allCases.map(\.rawValue).contains("Контакты"))
    }

    func testDropOnOrganizationCreatesManualMembershipOnce() async throws {
        let persistence = MembershipPersistence()
        let worker = PersonWorkspaceWorker(
            configuration: .init(connectionString: "synthetic-only", schema: "qa_persons_model"), storeFactory: { _ in persistence })
        let model = WorkspaceModel(worker: worker)
        await model.load()
        let person = try XCTUnwrap(model.persons.first { $0.kind == .person }).id
        let organization = try XCTUnwrap(model.persons.first { $0.kind == .organization }).id
        let first = await model.addToOrganization(personID: person, organizationID: organization)
        XCTAssertTrue(first)
        XCTAssertEqual(model.memberships.count, 1)
        XCTAssertEqual(model.memberships.first?.state, .confirmed)
        let second = await model.addToOrganization(personID: person, organizationID: organization)
        XCTAssertFalse(second, "a second drop on the same organization changes nothing")
        XCTAssertEqual(persistence.suggestCalls, 1)
    }

    func testHostConfiguresOnWorkspaceConfiguration() async throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], !dsn.isEmpty else {
            throw XCTSkip("MAKOSH_TEST_DATABASE_URL is required")
        }
        let schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defer { PersonsSidebarTests.dropSchema(schema, dsn: dsn) }
        let configuration = PersonWorkspaceConfiguration(connectionString: dsn, schema: schema)
        let worker = PersonWorkspaceWorker(configuration: configuration)
        _ = try await worker.open()
        let host = PersonsHost(synthetic: ["yandex": PersonSyntheticBook()])
        await host.configure(configuration: configuration, worker: worker)
        XCTAssertNil(host.failure)
        XCTAssertNotNil(host.model)
        XCTAssertNotNil(host.service)
        let snapshot = try await host.service?.snapshot()
        XCTAssertEqual(snapshot?.googleAvailable, false)
        await host.configure(configuration: configuration, worker: worker)
        XCTAssertNotNil(host.model, "a second configure is a no-op")
    }

    nonisolated static func dropSchema(_ schema: String, dsn: String) {
        guard schema.hasPrefix("makosh_test_"), let db = PQconnectdb(dsn), PQstatus(db) == CONNECTION_OK else { return }
        defer { PQfinish(db) }
        if let result = PQexec(db, "DROP SCHEMA IF EXISTS \"\(schema)\" CASCADE") { PQclear(result) }
    }
}

/// Two persons and one organization; memberships live in memory.
private final class MembershipPersistence: PersonWorkspacePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Person]
    private var memberships: [PersonMembership] = []
    private(set) var suggestCalls = 0
    init() {
        var organization = Person(displayName: "ИП Сидоров")
        organization.kind = .organization
        all = [Person(displayName: "Иванов"), organization]
    }
    func persons() throws -> [Person] { lock.withLock { all } }
    func duplicateCandidates() throws -> [DuplicateCandidate] { [] }
    func mergeHistory() throws -> [MergeRecord] { [] }
    func createPerson(draft: PersonDraft) throws -> UUID { throw StoreError.invalid("unused") }
    func updatePerson(id: UUID, draft: PersonDraft) throws { throw StoreError.invalid("unused") }
    func addNote(contactID: UUID, text: String) throws { throw StoreError.invalid("unused") }
    func addSourceNote(contactID: UUID, note: PersonNote) throws -> UUID { throw StoreError.invalid("unused") }
    func importDocument(_ document: ImportDocument) throws -> ImportResult { throw StoreError.invalid("unused") }
    func linkImportedPerson(_ incoming: ImportedPerson, source: ImportSource, fetchedAt: Date, contactID: UUID?) throws -> UUID {
        throw StoreError.invalid("unused")
    }
    func merge(survivorID: UUID, removedID: UUID) throws -> UUID { throw StoreError.invalid("unused") }
    func undoMerge(id: UUID) throws { throw StoreError.invalid("unused") }
    func allMemberships() throws -> [PersonMembership] { lock.withLock { memberships } }
    func memberships(of personID: UUID, includingRemoved: Bool) throws -> [PersonMembership] {
        lock.withLock { memberships.filter { $0.personID == personID } }
    }
    func suggestMembership(personID: UUID, organizationID: UUID, role: String, origin: MembershipOrigin) throws -> PersonMembership? {
        lock.withLock {
            suggestCalls += 1
            if memberships.contains(where: { $0.personID == personID && $0.organizationID == organizationID }) { return nil }
            let membership = PersonMembership(
                organizationID: organizationID, personID: personID, role: role, origin: origin, state: .confirmed)
            memberships.append(membership)
            return membership
        }
    }
}
