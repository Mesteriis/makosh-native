import XCTest
@testable import MakoshCore
@testable import MakoshApp
@testable import MakoshTeams

@MainActor final class TeamsDossierNavigationTests: XCTestCase {
    func testDestinationChangeWhileLinkingDoesNotSelectDossier() async throws { try await check(.link) }
    func testDestinationChangeWhileSnapshotLoadingDoesNotSelectDossier() async throws { try await check(.selectionSnapshot) }
    private func check(_ mode: TeamsDossierPauseStore.Mode) async throws {
        let db = try TeamsTestDatabase(); defer { try? db.cleanup() }
        let gate = TeamsDossierPauseStore.Gate()
        let store = try await BackgroundWork.run { try TeamsDossierPauseStore(configuration: db.configuration, mode: mode, gate: gate) }
        let workspace = WorkspaceModel(worker: ContactWorkspaceWorker(configuration: db.configuration, storeFactory: { _ in store }))
        await workspace.load()
        var current = true
        let person = TeamsPerson(userID: "88888888-8888-4888-8888-888888888888", tenantID: teamsTestScope.tenantID, displayName: "Synthetic guest", email: nil)
        let opening = Task { await workspace.openTeamsDossier(person, accountID: teamsTestScope.accountID, while: { current }) }
        await gate.arrived()
        current = false
        gate.release()
        let result = await opening.value
        XCTAssertNil(result)
        XCTAssertNil(workspace.selectedID)
        let contacts = try await BackgroundWork.run { try ContactStore(connectionString: db.configuration.connectionString, schema: db.configuration.schema).contacts() }
        XCTAssertEqual(contacts.count, 1, "Captured source link remains durable without obsolete navigation")
    }
}
private final class TeamsDossierPauseStore: ContactWorkspacePersistence, @unchecked Sendable {
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
    func addSourceNote(contactID: UUID, note: ContactNote) throws -> UUID { try store.addSourceNote(contactID: contactID, note: note) }
    func importDocument(_ document: ImportDocument) throws -> ImportResult { try store.importDocument(document) }
    func linkImportedContact(_ incoming: ImportedContact, source: ImportSource, fetchedAt: Date, contactID: UUID?) throws -> UUID {
        if mode == .link { gate.pause() }; return try store.linkImportedContact(incoming, source: source, fetchedAt: fetchedAt, contactID: contactID)
    }
    func merge(survivorID: UUID, removedID: UUID) throws -> UUID { try store.merge(survivorID: survivorID, removedID: removedID) }
    func undoMerge(id: UUID) throws { try store.undoMerge(id: id) }
}
