import Foundation
import XCTest
@testable import MakoshApp
@testable import MakoshCore

@MainActor final class WorkspaceModelTests: XCTestCase {
    func testStartupDoesNotReadPersistenceInInitializerAndPublishesAfterAwait() async throws {
        let probe = WorkspacePersistenceProbe()
        let model = WorkspaceModel(worker: worker(probe: probe, onOpen: {
            let gate = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { probe.heartbeat(); gate.signal() }
            probe.recordProgress(gate.wait(timeout: .now() + 1) == .success)
        }))
        XCTAssertEqual(probe.opens, 0)
        XCTAssertFalse(model.ready)
        await model.load()
        XCTAssertTrue(model.ready)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.contacts.map(\.displayName), ["First", "Second"])
        XCTAssertTrue(probe.progressed)
        XCTAssertEqual(probe.heartbeats, 1)
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertTrue(model.canWrite)
    }

    func testSaveDoesNotReplaceSelectionChangedWhileWorkerRuns() async throws {
        let probe = WorkspacePersistenceProbe()
        let model = WorkspaceModel(worker: worker(probe: probe, onWrite: {
            let gate = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { probe.onMainWrite?(); gate.signal() }
            _ = gate.wait(timeout: .now() + 1)
        }))
        await model.load()
        let first = try XCTUnwrap(model.contacts.first?.id), second = try XCTUnwrap(model.contacts.last?.id)
        model.selectedID = first
        probe.onMainWrite = { model.selectedID = second }
        let saved = await model.save(.init(displayName: "Created"), id: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.selectedID, second)
        XCTAssertEqual(model.contacts.count, 3)
        XCTAssertFalse(probe.ranOnMain)
    }

    func testBusyGuardRejectsSecondSubmissionWhileFirstIsRunning() async throws {
        let probe = WorkspacePersistenceProbe()
        let started = expectation(description: "Persistence entered")
        let release = DispatchSemaphore(value: 0)
        let model = WorkspaceModel(worker: worker(probe: probe, onWrite: {
            started.fulfill()
            _ = release.wait(timeout: .now() + 2)
        }))
        await model.load()
        let first = Task { await model.save(.init(displayName: "Created"), id: nil) }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(model.busy)
        let repeated = await model.save(.init(displayName: "Duplicate"), id: nil)
        XCTAssertFalse(repeated)
        release.signal()
        let committed = await first.value
        XCTAssertTrue(committed)
        XCTAssertEqual(probe.writes, 1)
        XCTAssertEqual(model.contacts.count, 3)
    }

    func testCommittedRefreshFailureClosesWriteAndDisablesReplay() async throws {
        let probe = WorkspacePersistenceProbe()
        let model = WorkspaceModel(worker: worker(probe: probe, failRefreshAfterWrite: true))
        await model.load()
        let saved = await model.save(.init(displayName: "Committed"), id: nil)
        XCTAssertTrue(saved, "Editor must close after known COMMIT even if refresh fails")
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.canWrite)
        let repeated = await model.save(.init(displayName: "Repeated"), id: nil)
        XCTAssertFalse(repeated)
        XCTAssertEqual(probe.writes, 1)
    }

    func testNoteTargetsCapturedContactAndPublishesRevision() async throws {
        let probe = WorkspacePersistenceProbe()
        let model = WorkspaceModel(worker: worker(probe: probe))
        await model.load()
        let first = try XCTUnwrap(model.contacts.first), second = try XCTUnwrap(model.contacts.last)
        model.selectedID = second.id
        let saved = await model.addNote("Synthetic note", contactID: first.id)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(model.contacts.first?.notes.map(\.text), ["Synthetic note"])
        XCTAssertEqual(model.contacts.first?.revision, first.revision + 1)
        XCTAssertEqual(model.contacts.last?.notes.count, 0)
    }

    private func worker(probe: WorkspacePersistenceProbe, onOpen: @escaping @Sendable () -> Void = {},
                        onWrite: @escaping @Sendable () -> Void = {}, failRefreshAfterWrite: Bool = false) -> ContactWorkspaceWorker {
        ContactWorkspaceWorker(configuration: .init(connectionString: "synthetic-only", schema: "qa_telegram_dossier_model"), storeFactory: { _ in
            probe.open(); onOpen()
            return WorkspacePersistence(probe: probe, onWrite: onWrite, failRefreshAfterWrite: failRefreshAfterWrite)
        })
    }
}

private final class WorkspacePersistenceProbe: @unchecked Sendable {
    @MainActor init() {}
    private let lock = NSLock()
    private var openCount = 0, writeCount = 0, beats = 0
    private var main = false, progress = false
    @MainActor var onMainWrite: (() -> Void)?
    var opens: Int { lock.withLock { openCount } }
    var heartbeats: Int { lock.withLock { beats } }
    var writes: Int { lock.withLock { writeCount } }
    var progressed: Bool { lock.withLock { progress } }
    var ranOnMain: Bool { lock.withLock { main } }
    func open() { lock.withLock { openCount += 1; main = main || Thread.isMainThread } }
    func write() { lock.withLock { writeCount += 1; main = main || Thread.isMainThread } }
    func heartbeat() { lock.withLock { beats += 1 } }
    func recordProgress(_ value: Bool) { lock.withLock { progress = value } }
}

private final class WorkspacePersistence: ContactWorkspacePersistence {
    let probe: WorkspacePersistenceProbe, onWrite: @Sendable () -> Void
    let failRefreshAfterWrite: Bool
    var all = [Contact(displayName: "First"), Contact(displayName: "Second")]
    init(probe: WorkspacePersistenceProbe, onWrite: @escaping @Sendable () -> Void, failRefreshAfterWrite: Bool) {
        self.probe = probe; self.onWrite = onWrite; self.failRefreshAfterWrite = failRefreshAfterWrite
    }
    func contacts() throws -> [Contact] {
        if failRefreshAfterWrite && probe.writes > 0 { throw StoreError.database("synthetic refresh failed") }
        return all
    }
    func duplicateCandidates() throws -> [DuplicateCandidate] { [] }
    func mergeHistory() throws -> [MergeRecord] { [] }
    func createContact(draft: ContactDraft) throws -> UUID {
        probe.write(); onWrite()
        let contact = Contact(displayName: draft.displayName); all.append(contact); return contact.id
    }
    func updateContact(id: UUID, draft: ContactDraft) throws { throw StoreError.invalid("unused") }
    func addNote(contactID: UUID, text: String) throws {
        probe.write(); onWrite()
        guard let index = all.firstIndex(where: { $0.id == contactID }) else { throw StoreError.missingContact }
        all[index].notes.append(.init(text: text, source: .init(identity: .init(service: "synthetic", accountID: "test", externalID: "local"))))
        all[index].revision += 1
    }
    func importDocument(_ document: ImportDocument) throws -> ImportResult { throw StoreError.invalid("unused") }
    func addSourceNote(contactID: UUID, note: ContactNote) throws -> UUID {
        probe.write(); onWrite()
        guard let index = all.firstIndex(where: { $0.id == contactID }) else { throw StoreError.missingContact }
        all[index].notes.append(note); all[index].revision += 1; return contactID
    }
    func linkImportedContact(_ incoming: ImportedContact, source: ImportSource, fetchedAt: Date, contactID: UUID?) throws -> UUID { throw StoreError.invalid("unused") }
    func merge(survivorID: UUID, removedID: UUID) throws -> UUID { throw StoreError.invalid("unused") }
    func undoMerge(id: UUID) throws { throw StoreError.invalid("unused") }
}
