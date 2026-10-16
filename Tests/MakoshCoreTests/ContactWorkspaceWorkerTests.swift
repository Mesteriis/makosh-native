import Foundation
import XCTest
@testable import MakoshCore

final class ContactWorkspaceWorkerTests: XCTestCase {
    @MainActor func testSlowOpeningAndSnapshotLeaveMainActorResponsive() async throws {
        let probe = ContactWorkProbe()
        let worker = ContactWorkspaceWorker(configuration: configuration(), storeFactory: { _ in
            probe.recordThread()
            let gate = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { probe.heartbeat(); gate.signal() }
            probe.recordProgress(gate.wait(timeout: .now() + 1) == .success)
            return ContactWorkStore(probe: probe)
        })
        let opened = try await worker.open()
        XCTAssertTrue(opened.snapshot.contacts.isEmpty)
        XCTAssertTrue(probe.progressed)
        XCTAssertEqual(probe.heartbeats, 1)
        XCTAssertFalse(probe.ranOnMain)
    }

    func testConcurrentCommandsAreSerializedWithDistinctRevisionSnapshots() async throws {
        let probe = ContactWorkProbe(), id = UUID()
        let worker = ContactWorkspaceWorker(configuration: configuration(), storeFactory: { _ in
            ContactWorkStore(probe: probe, initial: Contact(id: id, displayName: "Synthetic"), delay: 0.05)
        })
        _ = try await worker.open()
        let revisions = try await withThrowingTaskGroup(of: Int.self) { group in
            for text in ["First", "Second"] {
                group.addTask {
                    let result = try await worker.apply(.addNote(contactID: id, text: text))
                    return try XCTUnwrap(result.snapshot?.contacts.first?.revision)
                }
            }
            var values: [Int] = []
            for try await revision in group { values.append(revision) }
            return values.sorted()
        }
        let final = try await worker.snapshot()
        XCTAssertEqual(revisions, [2, 3])
        XCTAssertEqual(Set(final.contacts[0].notes.map(\.text)), ["First", "Second"])
        XCTAssertFalse(probe.overlapped)
        XCTAssertFalse(probe.ranOnMain)
    }

    func testCommittedWriteRefreshFailureReturnsSuccessAndBlocksReplay() async throws {
        let probe = ContactWorkProbe()
        let worker = ContactWorkspaceWorker(configuration: configuration(), storeFactory: { _ in
            ContactWorkStore(probe: probe, failRefreshAfterWrite: true)
        })
        _ = try await worker.open()
        let result = try await worker.apply(.save(draft: .init(displayName: "Committed"), id: nil))
        guard case .saved = result.value else { return XCTFail("Committed identity must be returned") }
        XCTAssertNil(result.snapshot)
        do {
            _ = try await worker.apply(.save(draft: .init(displayName: "Repeated"), id: nil))
            XCTFail("A stale display must not permit replay")
        } catch { XCTAssertTrue((error as? ContactWorkspaceError)?.blocksWrites == true) }
        XCTAssertEqual(probe.writeCount, 1)
    }

    func testUncertainCommitStopsFurtherMutationsWithoutRetry() async throws {
        let probe = ContactWorkProbe()
        let worker = ContactWorkspaceWorker(configuration: configuration(), storeFactory: { _ in
            ContactWorkStore(probe: probe, uncertainWrite: true)
        })
        _ = try await worker.open()
        for _ in 0..<2 {
            do {
                _ = try await worker.apply(.save(draft: .init(displayName: "Uncertain"), id: nil))
                XCTFail("Unknown COMMIT outcome must fail closed")
            } catch { XCTAssertTrue((error as? ContactWorkspaceError)?.blocksWrites == true) }
        }
        XCTAssertEqual(probe.writeCount, 1)
    }

    func testValidationFailureAllowsCorrectedSubmission() async throws {
        let probe = ContactWorkProbe()
        let worker = ContactWorkspaceWorker(configuration: configuration(), storeFactory: { _ in ContactWorkStore(probe: probe) })
        _ = try await worker.open()
        do {
            _ = try await worker.apply(.save(draft: .init(displayName: ""), id: nil))
            XCTFail("Empty name must fail")
        } catch { XCTAssertFalse((error as? ContactWorkspaceError)?.blocksWrites ?? true) }
        let result = try await worker.apply(.save(draft: .init(displayName: "Corrected"), id: nil))
        XCTAssertEqual(result.snapshot?.contacts.first?.displayName, "Corrected")
        XCTAssertEqual(probe.writeCount, 1)
    }

    func testExplicitSyntheticConfigurationRefusesPersonalAndMixedArchiveSchemas() async throws {
        for schemas in [("makosh", "makosh"), ("qa_telegram_dossier_test", "makosh")] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: url) }
            let bytes = try JSONSerialization.data(withJSONObject: ["connectionString": "host=127.0.0.1 port=1", "schema": schemas.0, "archiveSchema": schemas.1])
            try bytes.write(to: url)
            let worker = ContactWorkspaceWorker(arguments: ["test", "--database-config", url.path], requireExplicitDatabaseConfiguration: true)
            do { _ = try await worker.open(); XCTFail("Synthetic work must reject ordinary schemas before connecting") }
            catch { XCTAssertEqual(error as? ContactWorkspaceError, .invalidExplicitConfiguration) }
        }
    }

    func testSyntheticSchemaPrefixIsSelectedByServiceAndBothSchemasAreChecked() async throws {
        for (schema, archive, prefix, expected) in [
            ("qa_mail_ui_test", "qa_mail_ui_test", "qa_mail_", ContactWorkspaceError.setup),
            ("qa_mail_ui_test", "makosh", "qa_mail_", .invalidExplicitConfiguration),
            ("qa_mail_ui_test", "qa_mail_ui_test", "qa_telegram_dossier_", .invalidExplicitConfiguration),
            ("makosh", "makosh", "", .invalidExplicitConfiguration)
        ] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: url) }
            // Empty DSN deliberately reaches setup validation without opening a connection.
            try JSONSerialization.data(withJSONObject: ["connectionString": "", "schema": schema, "archiveSchema": archive]).write(to: url)
            let worker = ContactWorkspaceWorker(arguments: ["test", "--database-config", url.path], requireExplicitDatabaseConfiguration: true, syntheticSchemaPrefix: prefix)
            do { _ = try await worker.open(); XCTFail("Must reject before connecting") }
            catch { XCTAssertEqual(error as? ContactWorkspaceError, expected) }
        }
    }

    func testInvalidJSONDoesNotEnterMutationOrBlockCorrectedSave() async throws {
        let probe = ContactWorkProbe()
        let worker = ContactWorkspaceWorker(configuration: configuration(), storeFactory: { _ in ContactWorkStore(probe: probe) })
        _ = try await worker.open()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ invalid JSON".utf8).write(to: url)
        do { _ = try await worker.apply(.importFile(url)); XCTFail("Malformed import must fail before SQL") }
        catch { XCTAssertFalse((error as? ContactWorkspaceError)?.blocksWrites ?? true) }
        let result = try await worker.apply(.save(draft: .init(displayName: "Corrected"), id: nil))
        XCTAssertEqual(result.snapshot?.contacts.count, 1)
        XCTAssertEqual(probe.writeCount, 1)
    }

    func testFileImportPersistsIdempotentlyAndPreservesManualOverride() async throws {
        let database = try PostgresTestDatabase()
        defer { try? database.cleanup() }
        let worker = ContactWorkspaceWorker(configuration: .init(connectionString: database.connectionString, schema: database.schema))
        _ = try await worker.open()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = ImportDocument(source: .init(service: "synthetic", accountID: "test"), fetchedAt: Date(timeIntervalSince1970: 100),
            contacts: [.init(externalID: "1", displayName: "Imported", emails: ["synthetic@example.invalid"])])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url)
        let first = try await worker.apply(.importFile(url))
        XCTAssertEqual(first.value, .imported(.init(created: 1, updated: 0)))
        let contact = try XCTUnwrap(first.snapshot?.contacts.first)
        let edited = try await worker.apply(.save(draft: .init(displayName: "Manual"), id: contact.id))
        XCTAssertGreaterThan(try XCTUnwrap(edited.snapshot?.contacts.first?.revision), contact.revision)
        let repeated = try await worker.apply(.importFile(url))
        XCTAssertEqual(repeated.value, .imported(.init(created: 0, updated: 0)))
        XCTAssertEqual(repeated.snapshot?.contacts.first?.displayName, "Manual")
        XCTAssertEqual(repeated.snapshot?.contacts.first?.identities.first?.externalID, "1")
    }

    func testLinkMergeAndUndoPreserveIdentityAndRejectUndoAfterLaterEdit() async throws {
        let database = try PostgresTestDatabase()
        defer { try? database.cleanup() }
        let worker = ContactWorkspaceWorker(configuration: .init(connectionString: database.connectionString, schema: database.schema))
        _ = try await worker.open()
        let first = try await worker.apply(.save(draft: .init(displayName: "First", emails: ["same@example.invalid"]), id: nil))
        let firstID = try XCTUnwrap(first.snapshot?.contacts.first?.id)
        let second = try await worker.apply(.save(draft: .init(displayName: "Second", emails: ["same@example.invalid"]), id: nil))
        let secondID = try XCTUnwrap(second.snapshot?.contacts.first(where: { $0.id != firstID })?.id)
        XCTAssertEqual(second.snapshot?.duplicates.count, 1)
        let linked = try await worker.apply(.link(.init(externalID: "synthetic-peer", displayName: "Source name"),
            source: .init(service: "telegram", accountID: "synthetic-account"), fetchedAt: Date(timeIntervalSince1970: 100), contactID: secondID))
        XCTAssertEqual(linked.value, .linked(secondID))
        let merged = try await worker.apply(.merge(survivorID: firstID, removedID: secondID))
        XCTAssertEqual(merged.snapshot?.contacts.count, 1)
        XCTAssertEqual(merged.snapshot?.contacts.first?.identities.first?.externalID, "synthetic-peer")
        let record = try XCTUnwrap(merged.snapshot?.merges.first)
        let undone = try await worker.apply(.undo(record.id))
        XCTAssertEqual(undone.snapshot?.contacts.count, 2)
        XCTAssertNotNil(undone.snapshot?.merges.first?.undoneAt)
        let remerged = try await worker.apply(.merge(survivorID: firstID, removedID: secondID))
        let later = try XCTUnwrap(remerged.snapshot?.merges.first(where: { $0.undoneAt == nil }))
        _ = try await worker.apply(.addNote(contactID: firstID, text: "Preserve later edit"))
        do { _ = try await worker.apply(.undo(later.id)); XCTFail("Stale undo must fail") }
        catch { XCTAssertFalse((error as? ContactWorkspaceError)?.blocksWrites ?? true) }
        let final = try await worker.snapshot()
        XCTAssertEqual(final.contacts.count, 1)
        XCTAssertEqual(final.contacts.first?.notes.first?.text, "Preserve later edit")
    }

    private func configuration() -> ContactWorkspaceConfiguration { .init(connectionString: "synthetic-only", schema: "qa_telegram_dossier_worker") }
}

private final class ContactWorkProbe: @unchecked Sendable {
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
    func beginWrite() { lock.withLock { writes += 1; active += 1; overlap = overlap || active > 1; main = main || Thread.isMainThread } }
    func endWrite() { lock.withLock { active -= 1 } }
}

/// The double replaces only slow/external persistence; worker ordering and result handling are real.
private final class ContactWorkStore: ContactWorkspacePersistence {
    let probe: ContactWorkProbe
    var all: [Contact]
    let delay: TimeInterval, failRefreshAfterWrite: Bool, uncertainWrite: Bool
    init(probe: ContactWorkProbe, initial: Contact? = nil, delay: TimeInterval = 0,
         failRefreshAfterWrite: Bool = false, uncertainWrite: Bool = false) {
        self.probe = probe; self.all = initial.map { [$0] } ?? []; self.delay = delay
        self.failRefreshAfterWrite = failRefreshAfterWrite; self.uncertainWrite = uncertainWrite
    }
    func contacts() throws -> [Contact] {
        probe.recordThread()
        if failRefreshAfterWrite && probe.writeCount > 0 { throw StoreError.database("synthetic refresh failed") }
        return all
    }
    func duplicateCandidates() throws -> [DuplicateCandidate] { probe.recordThread(); return [] }
    func mergeHistory() throws -> [MergeRecord] { probe.recordThread(); return [] }
    func createContact(draft: ContactDraft) throws -> UUID {
        guard !draft.displayName.isEmpty else { throw StoreError.invalid("Name required") }
        probe.beginWrite(); defer { probe.endWrite() }
        let contact = Contact(displayName: draft.displayName); all.append(contact)
        if uncertainWrite { throw StoreError.database("synthetic COMMIT lost") }
        return contact.id
    }
    func updateContact(id: UUID, draft: ContactDraft) throws { throw StoreError.invalid("unused") }
    func addNote(contactID: UUID, text: String) throws {
        probe.beginWrite(); defer { probe.endWrite() }
        Thread.sleep(forTimeInterval: delay)
        guard let index = all.firstIndex(where: { $0.id == contactID }) else { throw StoreError.missingContact }
        all[index].notes.append(.init(text: text, source: .init(identity: .init(service: "synthetic", accountID: "test", externalID: "local"))))
        all[index].revision += 1
    }
    func importDocument(_ document: ImportDocument) throws -> ImportResult { throw StoreError.invalid("unused") }
    func addSourceNote(contactID: UUID, note: ContactNote) throws -> UUID {
        probe.beginWrite(); defer { probe.endWrite() }
        guard let index = all.firstIndex(where: { $0.id == contactID }) else { throw StoreError.missingContact }
        all[index].notes.append(note); all[index].revision += 1
        if uncertainWrite { throw StoreError.database("synthetic COMMIT lost") }
        return contactID
    }
    func linkImportedContact(_ incoming: ImportedContact, source: ImportSource, fetchedAt: Date, contactID: UUID?) throws -> UUID { throw StoreError.invalid("unused") }
    func merge(survivorID: UUID, removedID: UUID) throws -> UUID { throw StoreError.invalid("unused") }
    func undoMerge(id: UUID) throws { throw StoreError.invalid("unused") }
}
