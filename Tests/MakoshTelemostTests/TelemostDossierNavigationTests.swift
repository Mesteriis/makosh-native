import XCTest
@testable import MakoshCore
@testable import MakoshApp
@testable import MakoshTelemost

@MainActor final class TelemostDossierNavigationTests: XCTestCase {
    func testDossierLinkRejectsChangedSelection() async throws { try await check(.link) }
    func testDossierSnapshotRejectsChangedWindow() async throws { try await check(.selectionSnapshot) }
    func testSearchRemovalRevokesDossierNavigation() async throws { try await check(.link, search: true) }
    private func check(_ mode: TelemostDossierPauseStore.Mode, search: Bool = false) async throws {
        let db = try TelemostTestDatabase(); defer { try? db.cleanup() }
        let gate = TelemostDossierPauseStore.Gate()
        let store = try await BackgroundWork.run { try TelemostDossierPauseStore(configuration: db.configuration, mode: mode, gate: gate) }
        let contact = try await BackgroundWork.run { try store.createContact(draft: .init(displayName: "QA contact")) }
        let contacts = ContactWorkspaceWorker(configuration: db.configuration, storeFactory: { _ in store })
        let workspace = WorkspaceModel(worker: contacts); await workspace.load()
        let service = TelemostWorker(repository: TelemostRepository(keyProvider: telemostTestKey), api: TelemostAPI(transport: TelemostScriptedHTTP([])), vault: TelemostMemoryVault(), contacts: contacts)
        let telemost = TelemostWorkspaceModel(service: service, opener: { _ in false })
        await telemost.start(configuration: db.configuration); await telemost.addLink("https://telemost.yandex.ru/j/dossier")
        var current = true
        let opening = Task { await workspace.openTelemostDossier(telemost, contactID: contact, while: { current }) }
        await gate.arrived()
        if search { telemost.query = "no-matching-meeting"; await telemost.reload(); XCTAssertNil(telemost.selectedMeetingID) }
        else { current = false }
        gate.release()
        let result = await opening.value
        XCTAssertNil(result); XCTAssertNil(workspace.selectedID)
        let values = try await BackgroundWork.run { try ContactStore(connectionString: db.configuration.connectionString, schema: db.configuration.schema).contacts() }
        XCTAssertEqual(values.first?.notes.count, 1)
        await service.close()
    }
}
private final class TelemostDossierPauseStore: ContactWorkspacePersistence, @unchecked Sendable {
    enum Mode: Sendable { case link, selectionSnapshot }
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var hit = false
        private var waiter: CheckedContinuation<Void, Never>?
        func pause() {
            let waiting = lock.withLock { hit = true; let value = waiter; waiter = nil; return value }
            waiting?.resume(); semaphore.wait()
        }
        func arrived() async { await withCheckedContinuation { continuation in
            let ready = lock.withLock { if hit { return true }; waiter = continuation; return false }
            if ready { continuation.resume() }
        } }
        func release() { semaphore.signal() }
    }
    private let store: ContactStore
    private let mode: Mode
    private let gate: Gate
    private var snapshots = 0
    init(configuration: ContactWorkspaceConfiguration, mode: Mode, gate: Gate) throws {
        store = try ContactStore(connectionString: configuration.connectionString, schema: configuration.schema); self.mode = mode; self.gate = gate
    }
    func contacts() throws -> [Contact] { snapshots += 1; if mode == .selectionSnapshot, snapshots == 3 { gate.pause() }; return try store.contacts() }
    func duplicateCandidates() throws -> [DuplicateCandidate] { try store.duplicateCandidates() }
    func mergeHistory() throws -> [MergeRecord] { try store.mergeHistory() }
    func createContact(draft: ContactDraft) throws -> UUID { try store.createContact(draft: draft) }
    func updateContact(id: UUID, draft: ContactDraft) throws { try store.updateContact(id: id, draft: draft) }
    func addNote(contactID: UUID, text: String) throws { try store.addNote(contactID: contactID, text: text) }
    func addSourceNote(contactID: UUID, note: ContactNote) throws -> UUID { if mode == .link { gate.pause() }; return try store.addSourceNote(contactID: contactID, note: note) }
    func importDocument(_ document: ImportDocument) throws -> ImportResult { try store.importDocument(document) }
    func linkImportedContact(_ incoming: ImportedContact, source: ImportSource, fetchedAt: Date, contactID: UUID?) throws -> UUID {
        return try store.linkImportedContact(incoming, source: source, fetchedAt: fetchedAt, contactID: contactID)
    }
    func merge(survivorID: UUID, removedID: UUID) throws -> UUID { try store.merge(survivorID: survivorID, removedID: removedID) }
    func undoMerge(id: UUID) throws { try store.undoMerge(id: id) }
}
