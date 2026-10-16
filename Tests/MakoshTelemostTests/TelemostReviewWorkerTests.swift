import XCTest
@testable import MakoshTelemost

extension TelemostWorkerTests {
    func testRejectedCredentialRequiresLoginAcrossConnectAndRestart() async throws {
        let http = TelemostScriptedHTTP([telemostJSON("{}", status: 401)] + Array(repeating: telemostJSON(telemostConferenceFixture, status: 201), count: 10))
        let fixture = try await fixture(api: http)
        _ = try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins))
        do { _ = try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins)); XCTFail("401 token reused") } catch {}
        do { try await fixture.worker.connect(accountID: telemostTestAccountID); XCTFail("known rejected token reopened") } catch {}
        let state = try await fixture.worker.snapshot(); XCTAssertNil(state.grantedCapabilities[telemostTestAccountID])
        await fixture.worker.close()
        let reopened = TelemostWorker(repository: TelemostRepository(keyProvider: telemostTestKey), api: TelemostAPI(transport: http), oauth: TelemostOAuth(transport: TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture)])), vault: fixture.vault)
        try await reopened.open(configuration: fixture.db.configuration)
        do { try await reopened.connect(accountID: telemostTestAccountID); XCTFail("rejected token restored after restart") } catch {}
        let before = await http.requests; XCTAssertEqual(before.count, 1)
        let loads = await fixture.vault.loads; XCTAssertEqual(loads, 0)
        let request = try await reopened.authorize(accountID: telemostTestAccountID, mode: .browserCallback)
        let grant = try await reopened.completeAuthorization(id: request.id, callback: telemostCallback(request))
        try await reopened.confirmGrant(grant, accountID: telemostTestAccountID)
        _ = try await reopened.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins))
        let after = await http.requests; XCTAssertEqual(after.count, 2)
        await reopened.close()
    }
    func testUnknownPatchCannotDismissWithoutExactRead() async throws {
        let http = TelemostScriptedHTTP([telemostJSON("{}", status: 503), telemostJSON(telemostConferenceFixture)])
        let fixture = try await fixture(api: http)
        let id = try await fixture.worker.update(scope: telemostTestScope, patch: .init(waitingRoom: .admins))
        do { try await fixture.worker.resolve(operationID: id, resolution: .dismissUnknownAndAllowNewAttempt); XCTFail("PATCH bypassed GET") } catch {}
        let pending = try await fixture.repo.operation(id: id); XCTAssertEqual(pending.state, .unknown)
        guard pending.state == .unknown else { return }
        try await fixture.worker.resolve(operationID: id, resolution: .attachVerifiedMeetingURL(try .init("https://telemost.yandex.ru/j/123")))
        let observed = try await fixture.repo.operation(id: id); XCTAssertEqual(observed.state, .resolved); XCTAssertNotNil(observed.receipt)
        let requests = await http.requests; XCTAssertEqual(requests.map(\.httpMethod), ["PATCH", "GET"])
    }
    func testStorageCannotResolveUnknownPatchWithoutObservation() async throws {
        let fixture = try await fixture(api: TelemostScriptedHTTP([telemostJSON("{}", status: 503)]))
        let id = try await fixture.worker.update(scope: telemostTestScope, patch: .init(waitingRoom: .admins))
        let lease = try await fixture.repo.acquireLease(accountID: telemostTestAccountID, operationID: id, kind: .dispatch)
        do { try await fixture.repo.resolveUnknown(operationID: id); XCTFail("storage bypassed PATCH observation") } catch {}
        try await fixture.repo.releaseLease(lease)
        let value = try await fixture.repo.operation(id: id); XCTAssertEqual(value.state, .unknown)
    }
}

extension TelemostWorkerTests {
    func testStaleCredentialEpochCannotInvalidateConfirmedReauthorization() async throws {
        let auth = TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture), telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture)])
        let fixture = try await fixture(api: TelemostScriptedHTTP([]), auth: auth)
        let old = try await fixture.repo.credentialGate(accountID: telemostTestAccountID)
        let request = try await fixture.worker.authorize(accountID: telemostTestAccountID, mode: .browserCallback)
        let grant = try await fixture.worker.completeAuthorization(id: request.id, callback: telemostCallback(request))
        try await fixture.worker.confirmGrant(grant, accountID: telemostTestAccountID)
        let current = try await fixture.repo.credentialGate(accountID: telemostTestAccountID); XCTAssertNotEqual(old.epoch, current.epoch)
        let lease = try await fixture.repo.acquireLease(accountID: telemostTestAccountID, operationID: UUID(), kind: .dispatch)
        let changed = try await fixture.repo.rejectCredential(accountID: telemostTestAccountID, epoch: old.epoch, lease: lease)
        try await fixture.repo.releaseLease(lease)
        XCTAssertFalse(changed)
        let after = try await fixture.repo.credentialGate(accountID: telemostTestAccountID); XCTAssertFalse(after.requiresLogin); XCTAssertEqual(after.epoch, current.epoch)
    }
    func testReadAndResolution401AlsoRequireReauthorization() async throws {
        for resolution in [false, true] {
            let responses = (resolution ? [telemostJSON("{}", status: 503)] : []) + [telemostJSON("{}", status: 401)]
            let http = TelemostScriptedHTTP(responses), fixture = try await fixture(api: http)
            if resolution {
                let id = try await fixture.worker.update(scope: telemostTestScope, patch: .init(waitingRoom: .admins))
                do { try await fixture.worker.resolve(operationID: id, resolution: .attachVerifiedMeetingURL(try .init("https://telemost.yandex.ru/j/123"))); XCTFail("read401 hidden") } catch {}
                let operation = try await fixture.repo.operation(id: id); XCTAssertEqual(operation.state, .unknown)
            } else {
                do { try await fixture.worker.refresh(scope: telemostTestScope); XCTFail("read401 hidden") } catch {}
            }
            do { try await fixture.worker.connect(accountID: telemostTestAccountID); XCTFail("rejected read token reopened") } catch {}
            let state = try await fixture.worker.snapshot(); XCTAssertNil(state.grantedCapabilities[telemostTestAccountID])
            let gate = try await fixture.repo.credentialGate(accountID: telemostTestAccountID); XCTAssertTrue(gate.requiresLogin)
            let requests = await http.requests; XCTAssertEqual(requests.count, resolution ? 2 : 1)
        }
    }
    func testFailedNewOAuthGrantDoesNotRevokePreviousVerifiedCredential() async throws {
        var wire = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(telemostTokenFixture.utf8)) as? [String: Any]); wire["access_token"] = "rejected-new-fixture"
        let rejectedNewToken = TelemostHTTPResponse(status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: wire))
        let auth = TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture), rejectedNewToken, telemostJSON("{}", status: 401)])
        let http = TelemostScriptedHTTP([telemostJSON(telemostConferenceFixture, status: 201)]), fixture = try await fixture(api: http, auth: auth)
        let request = try await fixture.worker.authorize(accountID: telemostTestAccountID, mode: .browserCallback)
        do { _ = try await fixture.worker.completeAuthorization(id: request.id, callback: telemostCallback(request)); XCTFail("bad new grant accepted") } catch {}
        let gate = try await fixture.repo.credentialGate(accountID: telemostTestAccountID); XCTAssertFalse(gate.requiresLogin)
        _ = try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins))
        let requests = await http.requests; XCTAssertEqual(requests.count, 1)
    }
}
