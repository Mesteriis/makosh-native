import Foundation
import XCTest
@testable import MakoshCore

final class PersonWorkspaceWorkerTests: XCTestCase {
    @MainActor func testSlowOpeningAndSnapshotLeaveMainActorResponsive() async throws {
        let probe = PersonWorkProbe()
        let worker = PersonWorkspaceWorker(
            configuration: configuration(),
            storeFactory: { _ in
                probe.recordThread()
                let gate = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    probe.heartbeat()
                    gate.signal()
                }
                probe.recordProgress(gate.wait(timeout: .now() + 1) == .success)
                return PersonWorkStore(probe: probe)
            })
        let opened = try await worker.open()
        XCTAssertTrue(opened.snapshot.persons.isEmpty)
        XCTAssertTrue(probe.progressed)
        XCTAssertEqual(probe.heartbeats, 1)
        XCTAssertFalse(probe.ranOnMain)
    }

    func testConcurrentCommandsAreSerializedWithDistinctRevisionSnapshots() async throws {
        let probe = PersonWorkProbe(), id = UUID()
        let worker = PersonWorkspaceWorker(
            configuration: configuration(),
            storeFactory: { _ in
                PersonWorkStore(probe: probe, initial: Person(id: id, displayName: "Synthetic"), delay: 0.05)
            })
        _ = try await worker.open()
        let revisions = try await withThrowingTaskGroup(of: Int.self) { group in
            for text in ["First", "Second"] {
                group.addTask {
                    let result = try await worker.apply(.addNote(contactID: id, text: text))
                    return try XCTUnwrap(result.snapshot?.persons.first?.revision)
                }
            }
            var values: [Int] = []
            for try await revision in group { values.append(revision) }
            return values.sorted()
        }
        let final = try await worker.snapshot()
        XCTAssertEqual(revisions, [2, 3])
        XCTAssertEqual(Set(final.persons[0].notes.map(\.text)), ["First", "Second"])
        XCTAssertFalse(probe.overlapped)
        XCTAssertFalse(probe.ranOnMain)
    }

    func testCommittedWriteRefreshFailureReturnsSuccessAndBlocksReplay() async throws {
        let probe = PersonWorkProbe()
        let worker = PersonWorkspaceWorker(
            configuration: configuration(),
            storeFactory: { _ in
                PersonWorkStore(probe: probe, failRefreshAfterWrite: true)
            })
        _ = try await worker.open()
        let result = try await worker.apply(.save(draft: .init(displayName: "Committed"), id: nil))
        guard case .saved = result.value else { return XCTFail("Committed identity must be returned") }
        XCTAssertNil(result.snapshot)
        do {
            _ = try await worker.apply(.save(draft: .init(displayName: "Repeated"), id: nil))
            XCTFail("A stale display must not permit replay")
        } catch { XCTAssertTrue((error as? PersonWorkspaceError)?.blocksWrites == true) }
        XCTAssertEqual(probe.writeCount, 1)
    }

    func testUncertainCommitStopsFurtherMutationsWithoutRetry() async throws {
        let probe = PersonWorkProbe()
        let worker = PersonWorkspaceWorker(
            configuration: configuration(),
            storeFactory: { _ in
                PersonWorkStore(probe: probe, uncertainWrite: true)
            })
        _ = try await worker.open()
        for _ in 0..<2 {
            do {
                _ = try await worker.apply(.save(draft: .init(displayName: "Uncertain"), id: nil))
                XCTFail("Unknown COMMIT outcome must fail closed")
            } catch { XCTAssertTrue((error as? PersonWorkspaceError)?.blocksWrites == true) }
        }
        XCTAssertEqual(probe.writeCount, 1)
    }

    func testValidationFailureAllowsCorrectedSubmission() async throws {
        let probe = PersonWorkProbe()
        let worker = PersonWorkspaceWorker(configuration: configuration(), storeFactory: { _ in PersonWorkStore(probe: probe) })
        _ = try await worker.open()
        do {
            _ = try await worker.apply(.save(draft: .init(displayName: ""), id: nil))
            XCTFail("Empty name must fail")
        } catch { XCTAssertFalse((error as? PersonWorkspaceError)?.blocksWrites ?? true) }
        let result = try await worker.apply(.save(draft: .init(displayName: "Corrected"), id: nil))
        XCTAssertEqual(result.snapshot?.persons.first?.displayName, "Corrected")
        XCTAssertEqual(probe.writeCount, 1)
    }

    func testExplicitSyntheticConfigurationRefusesPersonalAndMixedArchiveSchemas() async throws {
        for schemas in [("makosh", "makosh"), ("qa_telegram_dossier_test", "makosh")] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: url) }
            let bytes = try JSONSerialization.data(withJSONObject: [
                "connectionString": "host=127.0.0.1 port=1", "schema": schemas.0, "archiveSchema": schemas.1,
            ])
            try bytes.write(to: url)
            let worker = PersonWorkspaceWorker(
                arguments: ["test", "--database-config", url.path], requireExplicitDatabaseConfiguration: true)
            do {
                _ = try await worker.open()
                XCTFail("Synthetic work must reject ordinary schemas before connecting")
            } catch { XCTAssertEqual(error as? PersonWorkspaceError, .invalidExplicitConfiguration) }
        }
    }

    func testSyntheticSchemaPrefixIsSelectedByServiceAndBothSchemasAreChecked() async throws {
        for (schema, archive, prefix, expected) in [
            ("qa_mail_ui_test", "qa_mail_ui_test", "qa_mail_", PersonWorkspaceError.setup),
            ("qa_mail_ui_test", "makosh", "qa_mail_", .invalidExplicitConfiguration),
            ("qa_mail_ui_test", "qa_mail_ui_test", "qa_telegram_dossier_", .invalidExplicitConfiguration),
            ("makosh", "makosh", "", .invalidExplicitConfiguration),
        ] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: url) }
            // Empty DSN deliberately reaches setup validation without opening a connection.
            try JSONSerialization.data(withJSONObject: ["connectionString": "", "schema": schema, "archiveSchema": archive]).write(to: url)
            let worker = PersonWorkspaceWorker(
                arguments: ["test", "--database-config", url.path], requireExplicitDatabaseConfiguration: true,
                syntheticSchemaPrefix: prefix)
            do {
                _ = try await worker.open()
                XCTFail("Must reject before connecting")
            } catch { XCTAssertEqual(error as? PersonWorkspaceError, expected) }
        }
    }

    func testInvalidJSONDoesNotEnterMutationOrBlockCorrectedSave() async throws {
        let probe = PersonWorkProbe()
        let worker = PersonWorkspaceWorker(configuration: configuration(), storeFactory: { _ in PersonWorkStore(probe: probe) })
        _ = try await worker.open()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ invalid JSON".utf8).write(to: url)
        do {
            _ = try await worker.apply(.importFile(url))
            XCTFail("Malformed import must fail before SQL")
        } catch { XCTAssertFalse((error as? PersonWorkspaceError)?.blocksWrites ?? true) }
        let result = try await worker.apply(.save(draft: .init(displayName: "Corrected"), id: nil))
        XCTAssertEqual(result.snapshot?.persons.count, 1)
        XCTAssertEqual(probe.writeCount, 1)
    }

    func testFileImportPersistsIdempotentlyAndPreservesManualOverride() async throws {
        let database = try PostgresTestDatabase()
        defer { try? database.cleanup() }
        let worker = PersonWorkspaceWorker(configuration: .init(connectionString: database.connectionString, schema: database.schema))
        _ = try await worker.open()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = ImportDocument(
            source: .init(service: "synthetic", accountID: "test"), fetchedAt: Date(timeIntervalSince1970: 100),
            contacts: [.init(externalID: "1", displayName: "Imported", emails: ["synthetic@example.invalid"])])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url)
        let first = try await worker.apply(.importFile(url))
        XCTAssertEqual(first.value, .imported(.init(created: 1, updated: 0)))
        let contact = try XCTUnwrap(first.snapshot?.persons.first)
        let edited = try await worker.apply(.save(draft: .init(displayName: "Manual"), id: contact.id))
        XCTAssertGreaterThan(try XCTUnwrap(edited.snapshot?.persons.first?.revision), contact.revision)
        let repeated = try await worker.apply(.importFile(url))
        XCTAssertEqual(repeated.value, .imported(.init(created: 0, updated: 0)))
        XCTAssertEqual(repeated.snapshot?.persons.first?.displayName, "Manual")
        XCTAssertEqual(repeated.snapshot?.persons.first?.identities.first?.externalID, "1")
    }

    func testLinkMergeAndUndoPreserveIdentityAndRejectUndoAfterLaterEdit() async throws {
        let database = try PostgresTestDatabase()
        defer { try? database.cleanup() }
        let worker = PersonWorkspaceWorker(configuration: .init(connectionString: database.connectionString, schema: database.schema))
        _ = try await worker.open()
        let first = try await worker.apply(.save(draft: .init(displayName: "First", emails: ["same@example.invalid"]), id: nil))
        let firstID = try XCTUnwrap(first.snapshot?.persons.first?.id)
        let second = try await worker.apply(.save(draft: .init(displayName: "Second", emails: ["same@example.invalid"]), id: nil))
        let secondID = try XCTUnwrap(second.snapshot?.persons.first(where: { $0.id != firstID })?.id)
        XCTAssertEqual(second.snapshot?.duplicates.count, 1)
        let linked = try await worker.apply(
            .link(
                .init(externalID: "synthetic-peer", displayName: "Source name"),
                source: .init(service: "telegram", accountID: "synthetic-account"), fetchedAt: Date(timeIntervalSince1970: 100),
                contactID: secondID))
        XCTAssertEqual(linked.value, .linked(secondID))
        let merged = try await worker.apply(.merge(survivorID: firstID, removedID: secondID))
        XCTAssertEqual(merged.snapshot?.persons.count, 1)
        XCTAssertEqual(merged.snapshot?.persons.first?.identities.first?.externalID, "synthetic-peer")
        let record = try XCTUnwrap(merged.snapshot?.merges.first)
        let undone = try await worker.apply(.undo(record.id))
        XCTAssertEqual(undone.snapshot?.persons.count, 2)
        XCTAssertNotNil(undone.snapshot?.merges.first?.undoneAt)
        let remerged = try await worker.apply(.merge(survivorID: firstID, removedID: secondID))
        let later = try XCTUnwrap(remerged.snapshot?.merges.first(where: { $0.undoneAt == nil }))
        _ = try await worker.apply(.addNote(contactID: firstID, text: "Preserve later edit"))
        do {
            _ = try await worker.apply(.undo(later.id))
            XCTFail("Stale undo must fail")
        } catch { XCTAssertFalse((error as? PersonWorkspaceError)?.blocksWrites ?? true) }
        let final = try await worker.snapshot()
        XCTAssertEqual(final.persons.count, 1)
        XCTAssertEqual(final.persons.first?.notes.first?.text, "Preserve later edit")
    }

    func testNewCommandsReachTheStoreAndSnapshotCarriesMemberships() async throws {
        let database = try PostgresTestDatabase()
        defer { try? database.cleanup() }
        let worker = PersonWorkspaceWorker(configuration: .init(connectionString: database.connectionString, schema: database.schema))
        _ = try await worker.open()
        guard
            case .saved(let person) = try await worker.apply(.save(draft: .init(displayName: "Иванов", phones: ["+7 1", "+7 2"]), id: nil))
                .value
        else { return XCTFail("save") }
        guard case .organizationCreated(let organization) = try await worker.apply(.createOrganization(name: "ИП Сидоров")).value
        else { return XCTFail("createOrganization") }
        let suggested = try await worker.apply(.suggestMembership(personID: person, organizationID: organization, role: "Менеджер"))
        XCTAssertEqual(suggested.value, .membershipChanged)
        let membership = try XCTUnwrap(suggested.snapshot?.memberships.first)
        XCTAssertEqual(membership.state, .confirmed)
        let renamed = try await worker.apply(.setMembershipRole(id: membership.id, role: "Директор"))
        XCTAssertEqual(renamed.snapshot?.memberships.first?.role, "Директор")
        let withdrawn = try await worker.apply(.setMembershipState(id: membership.id, state: .removed))
        XCTAssertEqual(withdrawn.snapshot?.memberships.count, 0)
        let flagged = try await worker.apply(.setAddressBook(personID: person, on: true))
        XCTAssertEqual(flagged.value, .flagSet)
        XCTAssertEqual(flagged.snapshot?.persons.first { $0.id == person }?.addressBookOrigin, .user)
        let removed = try await worker.apply(.removeValue(personID: person, field: .phones, value: "+7 2"))
        XCTAssertEqual(removed.value, .valueRemoved)
        XCTAssertEqual(removed.snapshot?.persons.first { $0.id == person }?.phones, ["+7 1"])
        let restored = try await worker.apply(.restoreValue(personID: person, field: .phones, value: "+7 2"))
        XCTAssertEqual(restored.value, .valueRestored)
        XCTAssertEqual(restored.snapshot?.persons.first { $0.id == person }?.phones, ["+7 1", "+7 2"])
        let identity = ServiceIdentity(service: "telegram", accountID: "t", externalID: "42")
        _ = try await worker.apply(
            .link(
                .init(externalID: "42", displayName: "TG"), source: .init(service: "telegram", accountID: "t"), fetchedAt: Date(),
                contactID: person))
        let detached = try await worker.apply(.detachIdentity(personID: person, identity: identity))
        guard case .detached(let newID) = detached.value else { return XCTFail("detach") }
        XCTAssertEqual(detached.snapshot?.persons.first { $0.id == newID }?.identities, [identity])
        let deleted = try await worker.apply(.delete(personID: newID))
        XCTAssertEqual(deleted.value, .deleted)
        XCTAssertEqual(deleted.snapshot?.inactiveCount, 1)
        XCTAssertFalse(deleted.snapshot?.persons.contains { $0.id == newID } ?? true)
        let back = try await worker.apply(.restore(personID: newID))
        XCTAssertEqual(back.value, .restored)
        XCTAssertEqual(back.snapshot?.inactiveCount, 0)
        let summaries = try await worker.summaries(matching: "ива", limit: 10)
        XCTAssertEqual(summaries.map(\.displayName), ["Иванов"])
        let fetched = try await worker.person(id: person)
        XCTAssertEqual(fetched?.id, person)
        let owners = try await worker.persons(owning: identity)
        XCTAssertEqual(owners.map(\.id), [newID])
    }

    private func configuration() -> PersonWorkspaceConfiguration {
        .init(connectionString: "synthetic-only", schema: "qa_telegram_dossier_worker")
    }
}

private final class PersonWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var main = false, progress = false, overlap = false
    private var beats = 0, writes = 0, active = 0
    var ranOnMain: Bool { lock.withLock { main } }
    var progressed: Bool { lock.withLock { progress } }
    var heartbeats: Int { lock.withLock { beats } }
    var overlapped: Bool { lock.withLock { overlap } }
    var writeCount: Int { lock.withLock { writes } }
    func recordThread() { lock.withLock { main = main || Thread.isMainThread } }
    func recordProgress(_ value: Bool) { lock.withLock { progress = value } }
    func heartbeat() { lock.withLock { beats += 1 } }
    func beginWrite() {
        lock.withLock {
            writes += 1
            active += 1
            overlap = overlap || active > 1
            main = main || Thread.isMainThread
        }
    }
    func endWrite() { lock.withLock { active -= 1 } }
}

/// The double replaces only slow/external persistence; worker ordering and result handling are real.
private final class PersonWorkStore: PersonWorkspacePersistence {
    let probe: PersonWorkProbe
    var all: [Person]
    let delay: TimeInterval, failRefreshAfterWrite: Bool, uncertainWrite: Bool
    init(
        probe: PersonWorkProbe, initial: Person? = nil, delay: TimeInterval = 0,
        failRefreshAfterWrite: Bool = false, uncertainWrite: Bool = false
    ) {
        self.probe = probe
        self.all = initial.map { [$0] } ?? []
        self.delay = delay
        self.failRefreshAfterWrite = failRefreshAfterWrite
        self.uncertainWrite = uncertainWrite
    }
    func persons() throws -> [Person] {
        probe.recordThread()
        if failRefreshAfterWrite && probe.writeCount > 0 { throw StoreError.database("synthetic refresh failed") }
        return all
    }
    func duplicateCandidates() throws -> [DuplicateCandidate] {
        probe.recordThread()
        return []
    }
    func mergeHistory() throws -> [MergeRecord] {
        probe.recordThread()
        return []
    }
    func createPerson(draft: PersonDraft) throws -> UUID {
        guard !draft.displayName.isEmpty else { throw StoreError.invalid("Name required") }
        probe.beginWrite()
        defer { probe.endWrite() }
        let contact = Person(displayName: draft.displayName)
        all.append(contact)
        if uncertainWrite { throw StoreError.database("synthetic COMMIT lost") }
        return contact.id
    }
    func updatePerson(id: UUID, draft: PersonDraft) throws { throw StoreError.invalid("unused") }
    func addNote(contactID: UUID, text: String) throws {
        probe.beginWrite()
        defer { probe.endWrite() }
        Thread.sleep(forTimeInterval: delay)
        guard let index = all.firstIndex(where: { $0.id == contactID }) else { throw StoreError.missingPerson }
        all[index].notes.append(
            .init(text: text, source: .init(identity: .init(service: "synthetic", accountID: "test", externalID: "local"))))
        all[index].revision += 1
    }
    func importDocument(_ document: ImportDocument) throws -> ImportResult { throw StoreError.invalid("unused") }
    func addSourceNote(contactID: UUID, note: PersonNote) throws -> UUID {
        probe.beginWrite()
        defer { probe.endWrite() }
        guard let index = all.firstIndex(where: { $0.id == contactID }) else { throw StoreError.missingPerson }
        all[index].notes.append(note)
        all[index].revision += 1
        if uncertainWrite { throw StoreError.database("synthetic COMMIT lost") }
        return contactID
    }
    func linkImportedPerson(_ incoming: ImportedPerson, source: ImportSource, fetchedAt: Date, contactID: UUID?) throws -> UUID {
        throw StoreError.invalid("unused")
    }
    func merge(survivorID: UUID, removedID: UUID) throws -> UUID { throw StoreError.invalid("unused") }
    func undoMerge(id: UUID) throws { throw StoreError.invalid("unused") }
}
