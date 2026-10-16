import XCTest
@testable import MakoshTelemost

extension TelemostWorkerTests {
    func testDuplicatePagePreservesNewObservedEmailsAndRestartsOffset() async throws {
        let first = #"{"cohosts":["# + (0..<50).map { #"{"email":"person\#($0)@example.test"}"# }.joined(separator: ",") + "]}"
        let duplicate = #"{"cohosts":[{"email":"person0@example.test"},{"email":"new@example.test"}]}"#
        let fixture = try await self.fixture(api: TelemostScriptedHTTP([telemostJSON(telemostConferenceFixture), telemostJSON(first), telemostJSON(duplicate)]))
        do { try await fixture.worker.refresh(scope: telemostTestScope); XCTFail("overlap claimed complete") } catch {}
        let page = try await fixture.repo.page(accountID: telemostTestAccountID, query: "", before: nil, limit: 50)
        let local = try XCTUnwrap(page.values.first)
        XCTAssertFalse(local.cohostsComplete); XCTAssertEqual(local.cohostsNextOffset, 0)
        XCTAssertTrue(local.cohosts.contains("new@example.test"))
        let versions = try await fixture.repo.versions(meetingID: local.id)
        XCTAssertTrue(versions.contains { value in
            guard let object = try? JSONSerialization.jsonObject(with: value.payload) as? [String: Any],
                  let observed = object["lastCohostPage"] as? [String: Any] else { return false }
            return observed["emails"] as? [String] == ["person0@example.test", "new@example.test"]
        })
    }
    func testReducedScopeAndExpiryRejectBeforeAdmission() async throws {
        let clock = TelemostMutableDate()
        let narrow = #"{"access_token":"synthetic","token_type":"bearer","expires_in":5,"scope":"telemost-api:conferences.read"}"#
        let http = TelemostScriptedHTTP([])
        let fixture = try await self.fixture(api: http, auth: TelemostScriptedHTTP([telemostJSON(narrow), telemostJSON(telemostUserFixture)]), now: { clock.now() })
        do { _ = try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins)); XCTFail("missing scope") }
        catch { XCTAssertEqual(error as? TelemostFailure, .scopeDenied) }
        clock.advance()
        do { try await fixture.worker.refresh(scope: telemostTestScope); XCTFail("expired token") }
        catch { XCTAssertEqual(error as? TelemostFailure, .expired) }
        let requests = await http.requests, operations = try await fixture.repo.operations(accountID: telemostTestAccountID)
        XCTAssertTrue(requests.isEmpty); XCTAssertTrue(operations.isEmpty)
    }
    func testCloseDrainsAdmittedReceiptBeforeStorageTeardown() async throws {
        let http = TelemostPausedAPI(), fixture = try await self.fixture(api: http)
        let submit = Task { try await fixture.worker.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins)) }
        await http.wait()
        let close = Task { await fixture.worker.close() }
        for _ in 0..<100 {
            if await fixture.worker.closing { break }; await Task.yield()
        }
        let closing = await fixture.worker.closing; XCTAssertTrue(closing)
        await http.finish(); let id = try await submit.value; await close.value
        let reopened = TelemostRepository(keyProvider: telemostTestKey)
        try await reopened.open(configuration: fixture.db.configuration); addTeardownBlock { await reopened.close() }
        let value = try await reopened.operation(id: id); XCTAssertEqual(value.state, .accepted)
    }
    func testDifferentPrincipalReconnectPreservesPreviousSession() async throws {
        let otherUser = telemostUserFixture.replacingOccurrences(of: "synthetic-user", with: "another-user")
        let auth = TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture),
                                        telemostJSON(telemostTokenFixture), telemostJSON(otherUser)])
        let fixture = try await self.fixture(api: TelemostScriptedHTTP([]), auth: auth)
        let request = try await fixture.worker.authorize(accountID: telemostTestAccountID, mode: .browserCallback)
        do { _ = try await fixture.worker.completeAuthorization(id: request.id, callback: telemostCallback(request)); XCTFail("source rebound") } catch {}
        let token = await fixture.vault.load(accountID: telemostTestAccountID)
        let account = try await fixture.repo.account(id: telemostTestAccountID)
        XCTAssertEqual(token?.principal.userID, "synthetic-user"); XCTAssertEqual(account.principal?.userID, "synthetic-user")
    }
}
