import XCTest
@testable import MakoshTelemost

actor TelemostPausedVault: TelemostTokenStoring {
    var token: TelemostToken?
    var pending: CheckedContinuation<Void, Never>?, waiter: CheckedContinuation<Void, Never>?
    var entered = false
    func load(accountID: UUID) -> TelemostToken? { token }
    func save(_ token: TelemostToken, accountID: UUID) async { entered = true; waiter?.resume(); waiter = nil; await withCheckedContinuation { pending = $0 }; self.token = token }
    func remove(accountID: UUID) { token = nil }
    func wait() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
    func finish() { pending?.resume(); pending = nil }
}
@MainActor final class TelemostAuthCancellationTests: XCTestCase {
    func testCancellationDuringConfirmedVaultWriteKeepsLeaseAndRejectsActivation() async throws {
        let db = try TelemostTestDatabase(); addTeardownBlock { try db.cleanup() }
        let vault = TelemostPausedVault()
        let worker = TelemostWorker(repository: TelemostRepository(keyProvider: telemostTestKey), oauth: TelemostOAuth(transport: TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture)])), vault: vault)
        try await worker.open(configuration: db.configuration); try await worker.addAccount(telemostTestAccount)
        let request = try await worker.authorize(accountID: telemostTestAccountID, mode: .browserCallback)
        let grant = try await worker.completeAuthorization(id: request.id, callback: telemostCallback(request))
        let confirmation = Task { try await worker.confirmGrant(grant, accountID: telemostTestAccountID) }
        await vault.wait(); await worker.cancelAuthorization(id: request.id)
        do { _ = try await worker.authorize(accountID: telemostTestAccountID, mode: .browserCallback); XCTFail("vault writer lost held account lease") } catch { XCTAssertEqual(error as? TelemostFailure, .busy) }
        await vault.finish()
        do { try await confirmation.value; XCTFail("cancelled confirmation activated") } catch {}
        let state = try await worker.snapshot()
        XCTAssertNil(state.grantedCapabilities[telemostTestAccountID])
        XCTAssertNotEqual(state.connections[telemostTestAccountID], .authorized)
        await worker.close()
    }
}
