import XCTest
@testable import MakoshApp
@testable import MakoshCore
@testable import MakoshTelemost

/// Suspends the service boundary, not the conductor being tested.
actor TelemostServiceGate: TelemostServing {
    let base: any TelemostServing
    var kind: String?, entered = false
    var waiter: CheckedContinuation<Void, Never>?, pending: CheckedContinuation<Void, Never>?
    init(_ base: any TelemostServing) { self.base = base }
    func arm(_ kind: String) { self.kind = kind; entered = false }
    func pause(_ kind: String) async { guard self.kind == kind else { return }; self.kind = nil; entered = true; waiter?.resume(); waiter = nil; await withCheckedContinuation { pending = $0 } }
    func wait() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
    func release() { pending?.resume(); pending = nil }
    func open(configuration: ContactWorkspaceConfiguration) async throws { try await base.open(configuration: configuration) }
    func snapshot() async throws -> TelemostWorkspaceSnapshot { try await base.snapshot() }
    func addAccount(_ account: TelemostAccount) async throws { try await base.addAccount(account) }
    func authorize(accountID: UUID, mode: TelemostAuthorizationMode) async throws -> TelemostAuthorizationRequest { let value = try await base.authorize(accountID: accountID, mode: mode); await pause("login"); return value }
    func completeAuthorization(id: UUID, callback: URL) async throws -> TelemostGrantResult { try await base.completeAuthorization(id: id, callback: callback) }
    func completeAuthorization(id: UUID, code: String) async throws -> TelemostGrantResult { try await base.completeAuthorization(id: id, code: code) }
    func confirmGrant(_ grant: TelemostGrantResult, accountID: UUID) async throws { try await base.confirmGrant(grant, accountID: accountID) }
    func cancelAuthorization(id: UUID) async { await base.cancelAuthorization(id: id) }
    func connect(accountID: UUID) async throws { try await base.connect(accountID: accountID) }
    func disconnect(accountID: UUID) async { await base.disconnect(accountID: accountID) }
    func addLink(_ url: TelemostMeetingURL, accountID: UUID?) async throws -> UUID { try await base.addLink(url, accountID: accountID) }
    func refresh(scope: TelemostScope) async throws { await pause("refresh"); try await base.refresh(scope: scope) }
    func create(accountID: UUID, request: TelemostCreateRequest) async throws -> UUID { try await base.create(accountID: accountID, request: request) }
    func update(scope: TelemostScope, patch: TelemostMeetingPatch) async throws -> UUID { await pause("patch"); return try await base.update(scope: scope, patch: patch) }
    func resolve(operationID: UUID, resolution: TelemostResolution) async throws { try await base.resolve(operationID: operationID, resolution: resolution) }
    func page(accountID: UUID?, query: String, before: TelemostHistoryCursor?, limit: Int) async throws -> TelemostMeetingPage { let value = try await base.page(accountID: accountID, query: query, before: before, limit: limit); await pause("page"); return value }
    func saveLocal(_ meeting: TelemostLocalMeeting) async throws { try await base.saveLocal(meeting) }
    func versions(meetingID: UUID, before: Int64?, limit: Int) async throws -> [TelemostRetainedVersion] { try await base.versions(meetingID: meetingID, before: before, limit: limit) }
    func export(accountID: UUID?, to url: URL) async throws -> Int { let count = try await base.export(accountID: accountID, to: url); await pause("export"); return count }
    func close() async { await base.close() }
    func linkDossier(meetingID: UUID, contactID: UUID) async throws -> UUID { try await base.linkDossier(meetingID: meetingID, contactID: contactID) }
}
@MainActor final class TelemostConductorFenceTests: XCTestCase {
    func check(_ kind: String) async throws {
        let db = try TelemostTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repo = TelemostRepository(keyProvider: telemostTestKey)
        let worker = TelemostWorker(repository: repo, api: TelemostAPI(transport: TelemostScriptedHTTP([])), vault: TelemostMemoryVault())
        try await worker.open(configuration: db.configuration); try await worker.addAccount(telemostTestAccount)
        let url = try TelemostMeetingURL("https://telemost.yandex.ru/j/fence")
        let id = try await worker.addLink(url, accountID: telemostTestAccountID)
        try await repo.retain(.init(scope: .init(accountID: telemostTestAccountID, conferenceID: "fence"), joinURL: url, waitingRoomRaw: "ADMINS", retainedJSON: Data("{}".utf8)))
        let gate = TelemostServiceGate(worker), model = TelemostWorkspaceModel(service: gate, opener: { _ in false })
        await model.start(configuration: db.configuration); await model.selectAccount(telemostTestAccountID); model.selectMeeting(id)
        await gate.arm(kind)
        let export = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: export) }
        let work = Task {
            switch kind {
            case "page": await model.reload()
            case "login": await model.beginAuthorization(mode: .browserCallback)
            case "refresh": await model.refreshSelected()
            case "patch": await model.update(patch: .init(waitingRoom: .organization))
            default: await model.exportHistory(to: export)
            }
        }
        await gate.wait(); await model.selectAccount(nil); await gate.release(); await work.value
        XCTAssertNil(model.selectedAccountID); XCTAssertNil(model.selectedMeetingID)
        XCTAssertTrue(model.meetings.isEmpty); XCTAssertNil(model.authorization); XCTAssertNil(model.notice); XCTAssertNil(model.error)
        await worker.close()
    }
    func testSearchPageCannotReplaceChangedAccount() async throws { try await check("page") }
    func testLoginResultCannotReopenChangedAccount() async throws { try await check("login") }
    func testRefreshFailureCannotPublishIntoChangedAccount() async throws { try await check("refresh") }
    func testPatchFailureCannotPublishIntoChangedAccount() async throws { try await check("patch") }
    func testExportCompletionCannotPublishIntoChangedAccount() async throws { try await check("export") }
}
