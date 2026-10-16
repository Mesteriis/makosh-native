import XCTest
@testable import MakoshTelemost

actor TelemostMemoryVault: TelemostTokenStoring {
    var values: [UUID: TelemostToken] = [:]
    private(set) var loads = 0
    func load(accountID: UUID) -> TelemostToken? { loads += 1; return values[accountID] }
    func save(_ token: TelemostToken, accountID: UUID) { values[accountID] = token }
    func remove(accountID: UUID) { values[accountID] = nil }
}
actor TelemostPausedAPI: TelemostHTTPTransport {
    var pending: CheckedContinuation<TelemostHTTPResponse, any Error>?
    var waiting: CheckedContinuation<Void, Never>?
    var entered = false
    func response(to request: URLRequest) async throws -> TelemostHTTPResponse {
        entered = true; waiting?.resume(); waiting = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func wait() async { if entered { return }; await withCheckedContinuation { waiting = $0 } }
    func finish() { pending?.resume(returning: telemostJSON(telemostConferenceFixture, status: 201)); pending = nil }
}

@MainActor
final class TelemostWorkerTests: XCTestCase {
    struct Fixture {
        let db: TelemostTestDatabase
        let repo: TelemostRepository
        let worker: TelemostWorker
        let vault: TelemostMemoryVault
    }
    func fixture(api: any TelemostHTTPTransport, authorize: Bool = true, auth: (any TelemostHTTPTransport)? = nil,
                 now: @escaping @Sendable () -> Date = Date.init) async throws -> Fixture {
        let db = try TelemostTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repo = TelemostRepository(keyProvider: telemostTestKey), vault = TelemostMemoryVault()
        let oauth = TelemostOAuth(transport: auth ?? TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture)]), now: now)
        let worker = TelemostWorker(repository: repo, api: TelemostAPI(transport: api, clock: TelemostTestClock()), oauth: oauth, vault: vault, now: now)
        try await worker.open(configuration: db.configuration); try await worker.addAccount(telemostTestAccount)
        addTeardownBlock { await worker.close() }
        if authorize {
            let request = try await worker.authorize(accountID: telemostTestAccountID, mode: .browserCallback)
            let grant = try await worker.completeAuthorization(id: request.id, callback: telemostCallback(request))
            try await worker.confirmGrant(grant, accountID: telemostTestAccountID)
        }
        return .init(db: db, repo: repo, worker: worker, vault: vault)
    }
    func testCreateReceiptAndDefinitiveRejection() async throws {
        for status in [201, 400, 403] {
            let http = TelemostScriptedHTTP([telemostJSON(status == 201 ? telemostConferenceFixture : "{}", status: status)])
            let fixture = try await fixture(api: http)
            let id = try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins))
            let operation = try await fixture.repo.operation(id: id)
            XCTAssertEqual(operation.state, status == 201 ? .accepted : .rejected)
            let requests = await http.requests; XCTAssertEqual(requests.count, 1)
        }
    }
    func testUnknownCreateSurvivesRestartWithoutReplay() async throws {
        let http = TelemostScriptedHTTP([telemostJSON("{}", status: 201)])
        let fixture = try await fixture(api: http)
        let id = try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins))
        let original = try await fixture.repo.operation(id: id); XCTAssertEqual(original.state, .unknown)
        await fixture.worker.disconnect(accountID: telemostTestAccountID)
        try await fixture.worker.connect(accountID: telemostTestAccountID)
        do { _ = try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins)); XCTFail("uncertain create replay") } catch {}
        await fixture.worker.close()
        let reopened = TelemostRepository(keyProvider: telemostTestKey)
        try await reopened.open(configuration: fixture.db.configuration); addTeardownBlock { await reopened.close() }
        let restored = try await reopened.operation(id: id); XCTAssertEqual(restored.state, .unknown)
        let requests = await http.requests; XCTAssertEqual(requests.count, 1)
    }
    func testUnknownPatchRequiresReadReview() async throws {
        let http = TelemostScriptedHTTP([telemostJSON("{}", status: 503), telemostJSON(telemostConferenceFixture)])
        let fixture = try await fixture(api: http)
        let id = try await fixture.worker.update(scope: telemostTestScope, patch: .init(waitingRoom: .admins))
        let original = try await fixture.repo.operation(id: id); XCTAssertEqual(original.state, .unknown)
        try await fixture.worker.resolve(operationID: id, resolution: .attachVerifiedMeetingURL(try .init("https://telemost.yandex.ru/j/123")))
        let reviewed = try await fixture.repo.operation(id: id); XCTAssertEqual(reviewed.state, .resolved)
        let requests = await http.requests; XCTAssertEqual(requests.map(\.httpMethod), ["PATCH", "GET"])
    }
    func testGrantInstallLeaseAndPrincipalFence() async throws {
        let fixture = try await fixture(api: TelemostScriptedHTTP([]), authorize: false)
        let request = try await fixture.worker.authorize(accountID: telemostTestAccountID, mode: .browserCallback)
        let grant = try await fixture.worker.completeAuthorization(id: request.id, callback: telemostCallback(request))
        await fixture.worker.disconnect(accountID: telemostTestAccountID)
        do { try await fixture.worker.confirmGrant(grant, accountID: telemostTestAccountID); XCTFail("cancelled grant installed") } catch {}
        let value = await fixture.vault.load(accountID: telemostTestAccountID); XCTAssertNil(value)
    }
    func testLocalLinkDoesNotConnect() async throws {
        let http = TelemostScriptedHTTP([]), fixture = try await fixture(api: http, authorize: false)
        let url = try TelemostMeetingURL("https://telemost.yandex.ru/j/777")
        let first = try await fixture.worker.addLink(url, accountID: nil)
        let second = try await fixture.worker.addLink(url, accountID: nil)
        XCTAssertEqual(first, second)
        let requests = await http.requests, loads = await fixture.vault.loads
        XCTAssertTrue(requests.isEmpty); XCTAssertEqual(loads, 0)
    }
    func testPartialAndReorderedCohostPagesPreserveObservations() async throws {
        let fullPage = #"{"cohosts":["# + (0..<50).map { #"{"email":"person\#($0)@example.test"}"# }.joined(separator: ",") + "]}"
        let lastPage = #"{"cohosts":[{"email":"last@example.test"}]}"#
        let http = TelemostScriptedHTTP([telemostJSON(telemostConferenceFixture), telemostJSON(fullPage),
            telemostJSON("{}", status: 503), telemostJSON("{}", status: 503), telemostJSON("{}", status: 503),
            telemostJSON(telemostConferenceFixture), telemostJSON(lastPage)])
        let fixture = try await fixture(api: http)
        do { try await fixture.worker.refresh(scope: telemostTestScope); XCTFail("partial read claimed complete") } catch {}
        let page = try await fixture.worker.page(accountID: telemostTestAccountID, query: "", before: nil, limit: 50)
        let partial = try XCTUnwrap(page.values.first)
        XCTAssertFalse(partial.cohostsComplete); XCTAssertEqual(partial.cohosts.count, 50); XCTAssertEqual(partial.cohostsNextOffset, 50)
        try await fixture.worker.refresh(scope: telemostTestScope)
        let complete = try await fixture.repo.meeting(id: partial.id)
        XCTAssertTrue(complete.cohostsComplete); XCTAssertEqual(complete.cohosts.count, 51)
    }
    func testDisconnectFencesPublicationButRetainsReceipt() async throws {
        let http = TelemostPausedAPI(), fixture = try await fixture(api: http)
        let sending = Task { try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins)) }
        await http.wait(); await fixture.worker.disconnect(accountID: telemostTestAccountID); await http.finish()
        let id = try await sending.value, value = try await fixture.repo.operation(id: id)
        let snapshot = try await fixture.worker.snapshot()
        XCTAssertEqual(value.state, .accepted); XCTAssertEqual(snapshot.connections[telemostTestAccountID], .disconnected)
    }
    func testBusyDoesNotSpin() async throws {
        let http = TelemostScriptedHTTP([]), fixture = try await fixture(api: http)
        let lease = try await fixture.repo.acquireLease(accountID: telemostTestAccountID, operationID: UUID(), kind: .auth)
        do { _ = try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins)); XCTFail("busy dispatch") }
        catch { XCTAssertEqual(error as? TelemostFailure, .busy) }
        let requests = await http.requests; XCTAssertTrue(requests.isEmpty)
        let operations = try await fixture.repo.operations(accountID: telemostTestAccountID); XCTAssertTrue(operations.isEmpty)
        try await fixture.repo.releaseLease(lease)
    }
}
