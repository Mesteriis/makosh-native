import Foundation
import MakoshPersons
import XCTest

@testable import MakoshApp
@testable import MakoshCore

@MainActor
final class PersonCardModelTests: XCTestCase {
    private func model(_ persistence: CardPersistence) -> WorkspaceModel {
        WorkspaceModel(
            worker: PersonWorkspaceWorker(
                configuration: .init(connectionString: "synthetic-only", schema: "qa_persons_card"), storeFactory: { _ in persistence }))
    }

    func testDeleteIsSoftAndRestoreReturns() async throws {
        let persistence = CardPersistence()
        let model = model(persistence)
        await model.load()
        let id = try XCTUnwrap(model.persons.first).id
        let deleted = await model.deletePerson(id)
        XCTAssertTrue(deleted)
        XCTAssertEqual(persistence.commands, ["delete"])
        XCTAssertFalse(model.persons.contains { $0.id == id }, "a deleted person leaves the active list")
        XCTAssertEqual(model.inactiveCount, 1)
        let restored = await model.restorePerson(id)
        XCTAssertTrue(restored)
        XCTAssertEqual(persistence.commands, ["delete", "restore"])
        XCTAssertTrue(model.persons.contains { $0.id == id })
    }

    func testDetachSelectsNewPersonAndRemoveValueGoesThroughCommand() async throws {
        let persistence = CardPersistence()
        let model = model(persistence)
        await model.load()
        let id = try XCTUnwrap(model.persons.first).id
        model.selectedID = id
        let removed = await model.removeValue("+7 1", field: .phones, personID: id)
        XCTAssertTrue(removed)
        XCTAssertEqual(persistence.commands.last, "removeValue phones +7 1")
        let restored = await model.restoreValue("+7 1", field: .phones, personID: id)
        XCTAssertTrue(restored)
        XCTAssertEqual(persistence.commands.last, "restoreValue phones +7 1")
        let newID = await model.detachIdentity(ServiceIdentity(service: "telegram", accountID: "t", externalID: "1"), personID: id)
        XCTAssertNotNil(newID)
        XCTAssertEqual(model.selectedID, newID)
        XCTAssertEqual(persistence.commands.last, "detach telegram")
    }

    func testMergePickerFiltersByKindAndExcludesSelf() {
        let me = PersonSummary(
            id: UUID(), kind: .person, displayName: "Иванов", organization: "", jobTitle: "", firstEmail: nil, firstPhone: nil,
            addressBook: false, isActive: true, revision: 1)
        let other = PersonSummary(
            id: UUID(), kind: .person, displayName: "Петров", organization: "", jobTitle: "", firstEmail: nil, firstPhone: nil,
            addressBook: false, isActive: true, revision: 1)
        let organization = PersonSummary(
            id: UUID(), kind: .organization, displayName: "ИП Сидоров", organization: "", jobTitle: "", firstEmail: nil, firstPhone: nil,
            addressBook: false, isActive: true, revision: 1)
        XCTAssertEqual(
            PersonPicker.candidates(summaries: [me, other, organization], kind: .person, exclude: me.id, query: "").map(\.id), [other.id])
        XCTAssertEqual(
            PersonPicker.candidates(summaries: [me, other, organization], kind: .organization, exclude: me.id, query: "").map(\.id),
            [organization.id])
        XCTAssertTrue(PersonPicker.candidates(summaries: [me, other, organization], kind: .person, exclude: me.id, query: "сид").isEmpty)
        XCTAssertEqual(
            PersonPicker.candidates(summaries: [me, other, organization], kind: .person, exclude: nil, query: "пет").map(\.id), [other.id])
    }
}

/// Two persons; deletion, restoration, values and detachment happen in memory and are logged.
private final class CardPersistence: PersonWorkspacePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var all = [Person(displayName: "Иванов", phones: ["+7 1"]), Person(displayName: "Петров")]
    private(set) var commands: [String] = []
    private func log(_ command: String) { lock.withLock { commands.append(command) } }
    func persons() throws -> [Person] { lock.withLock { all.filter(\.isActive) } }
    func allPersons(includingInactive: Bool) throws -> [Person] { lock.withLock { includingInactive ? all : all.filter(\.isActive) } }
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
    func deletePerson(id: UUID) throws {
        log("delete")
        lock.withLock { if let index = all.firstIndex(where: { $0.id == id }) { all[index].deletedAt = Date() } }
    }
    func restorePerson(id: UUID) throws {
        log("restore")
        lock.withLock { if let index = all.firstIndex(where: { $0.id == id }) { all[index].deletedAt = nil } }
    }
    func removeValue(personID: UUID, field: PersonListField, value: String, reason: FormerReason) throws {
        log("removeValue \(field.rawValue) \(value)")
    }
    func restoreValue(personID: UUID, field: PersonListField, value: String) throws { log("restoreValue \(field.rawValue) \(value)") }
    func detachIdentity(personID: UUID, identity: ServiceIdentity) throws -> UUID {
        log("detach " + identity.service)
        let detached = Person(displayName: "Отделённая", identities: [identity])
        lock.withLock { all.append(detached) }
        return detached.id
    }
}
