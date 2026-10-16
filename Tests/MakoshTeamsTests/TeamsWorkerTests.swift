import XCTest
import MakoshCore
@testable import MakoshTeams

actor TeamsStopClock: TeamsRetryClock {
    private var interval: TimeInterval?
    private var observer: CheckedContinuation<TimeInterval, Never>?
    func sleep(seconds: TimeInterval) async throws {
        interval = seconds; observer?.resume(returning: seconds); observer = nil
        throw CancellationError()
    }
    func observed() async -> TimeInterval {
        if let interval { return interval }
        return await withCheckedContinuation { observer = $0 }
    }
}

@MainActor
final class TeamsWorkerTests: XCTestCase {
    let oauthConfiguration = TeamsOAuthConfiguration(clientID: "44444444-4444-4444-8444-444444444444", authority: "organizations")
    func database() throws -> TeamsTestDatabase {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }; return db
    }
    func bundle(expired: Bool = false) -> TeamsTokenBundle {
        TeamsTokenBundle(accessToken: "old-opaque", refreshToken: "refresh", idToken: nil,
            expiresAt: Date().addingTimeInterval(expired ? -1 : 3600), grantedScopes: ["Chat.Read", "User.Read"], expectedNonce: nil)
    }

    func testDisconnectedArchiveRemainsAvailable() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        _ = try await repository.commit(page: TeamsPage(values: [teamsTestMessage("offline original")], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: true)
        let http = TeamsRoutedHTTP([:])
        let worker = TeamsWorker(repository: repository, transport: http, vault: TeamsTokenVault(api: TeamsFakeKeychain()), automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        try await worker.disconnect(accountID: teamsTestContext.accountID)
        let page = try await worker.messages(scope: teamsTestScope, before: nil)
        XCTAssertEqual(page.values.map(\.body), ["offline original"])
        let archive = try await worker.archivePage(scope: teamsTestScope, before: nil)
        XCTAssertEqual(archive.count, 1)
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        await worker.shutdown()
    }

    func testCancelGrantAndSwitchAccountRejectLateIdentity() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let fixture = try TeamsRSAFixture()
        let http = TeamsRoutedHTTP([:])
        await http.hold("/v1.0/me")
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        let original = bundle()
        try await vault.save(original, accountID: teamsTestContext.accountID)
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        let presentation = try await worker.beginAuthorization(accountID: teamsTestContext.accountID, method: .browserPKCE, capabilities: [.basicChats])
        guard case let .browser(url) = presentation else { return XCTFail("No browser grant") }
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        let claims: [String: Any] = ["ver": "2.0", "aud": oauthConfiguration.clientID,
            "iss": "https://login.microsoftonline.com/\(teamsTestContext.principal.tenantID)/v2.0",
            "tid": teamsTestContext.principal.tenantID, "oid": teamsTestContext.principal.userID, "sub": "test", "name": "Test User", "nonce": query["nonce"]!,
            "iat": Date().timeIntervalSince1970 - 10, "nbf": Date().timeIntervalSince1970 - 10, "exp": Date().timeIntervalSince1970 + 3600]
        let token = try fixture.token(claims: claims)
        let response = try JSONSerialization.data(withJSONObject: ["access_token": "new-opaque", "refresh_token": "new-refresh", "id_token": token, "expires_in": 3600, "token_type": "Bearer", "scope": "Chat.Read User.Read"])
        await http.set("/organizations/oauth2/v2.0/token", responses: [TeamsHTTPResponse(status: 200, headers: [:], body: response)])
        await http.set("/organizations/v2.0/.well-known/openid-configuration", responses: [teamsJSON("{\"issuer\":\"https://login.microsoftonline.com/{tenantid}/v2.0\",\"jwks_uri\":\"https://login.microsoftonline.com/common/discovery/v2.0/keys\"}")])
        await http.set("/common/discovery/v2.0/keys", responses: [TeamsHTTPResponse(status: 200, headers: [:], body: fixture.jwks)])
        let callbackURL = URL(string: query["redirect_uri"]!)!
        let callback = Data("GET /callback?code=c&state=\(query["state"]!) HTTP/1.1\r\nHost: 127.0.0.1:\(callbackURL.port!)\r\n\r\n".utf8)
        let finishing = Task { try await worker.completeAuthorization(accountID: teamsTestContext.accountID, callback: callback) }
        await http.waitForHeldRequest()
        try await worker.cancelAuthorization(accountID: teamsTestContext.accountID)
        let second = try await worker.addAccount(name: "Second", configuration: oauthConfiguration, readOnly: true)
        await http.release(teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Test User\",\"mail\":null}"))
        do { try await finishing.value; XCTFail("Cancelled identity published") } catch is CancellationError {}
        let stored = try await vault.load(accountID: teamsTestContext.accountID)
        XCTAssertEqual(stored, original)
        let snapshot = try await worker.snapshot(accountID: second.id)
        XCTAssertEqual(snapshot.accountID, second.id)
        XCTAssertEqual(snapshot.state, .disconnected)
        await worker.shutdown()
    }

    func testIncrementalGrantCannotOverwriteSuspendedOtherSessionRefresh() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let fixture = try TeamsRSAFixture()
        let http = TeamsRoutedHTTP([:])
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        let original = bundle(expired: true)
        try await vault.save(original, accountID: teamsTestContext.accountID)
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        let second = TeamsRepository(keyProvider: teamsTestKey); try await second.open(configuration: db.configuration)
        let pinned = TeamsOAuthConfiguration(clientID: oauthConfiguration.clientID, authority: teamsTestContext.principal.tenantID)
        await http.hold("/" + pinned.authority + "/oauth2/v2.0/token")
        let session = TeamsSession(context: teamsTestContext, configuration: pinned, repository: second, vault: vault, transport: http)
        let refreshing = Task { try await session.token() }
        await http.waitForHeldRequest()
        let presentation = try await worker.beginAuthorization(accountID: teamsTestContext.accountID, method: .browserPKCE, capabilities: [.basicChats])
        guard case let .browser(url) = presentation else { return XCTFail("No browser grant") }
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        let claims: [String: Any] = ["ver": "2.0", "aud": oauthConfiguration.clientID,
            "iss": "https://login.microsoftonline.com/\(teamsTestContext.principal.tenantID)/v2.0",
            "tid": teamsTestContext.principal.tenantID, "oid": teamsTestContext.principal.userID, "sub": "test", "name": "Test User", "nonce": query["nonce"]!,
            "iat": Date().timeIntervalSince1970 - 10, "nbf": Date().timeIntervalSince1970 - 10, "exp": Date().timeIntervalSince1970 + 3600]
        let token = try fixture.token(claims: claims)
        let response = try JSONSerialization.data(withJSONObject: ["access_token": "new-opaque", "refresh_token": "new-refresh", "id_token": token, "expires_in": 3600, "token_type": "Bearer", "scope": "Chat.Read User.Read"])
        await http.set("/organizations/oauth2/v2.0/token", responses: [TeamsHTTPResponse(status: 200, headers: [:], body: response)])
        await http.set("/organizations/v2.0/.well-known/openid-configuration", responses: [teamsJSON("{\"issuer\":\"https://login.microsoftonline.com/{tenantid}/v2.0\",\"jwks_uri\":\"https://login.microsoftonline.com/common/discovery/v2.0/keys\"}")])
        await http.set("/common/discovery/v2.0/keys", responses: [TeamsHTTPResponse(status: 200, headers: [:], body: fixture.jwks)])
        await http.set("/v1.0/me", responses: [teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Test User\"}")])
        await http.set("/" + pinned.authority + "/v2.0/.well-known/openid-configuration", responses: [teamsJSON("{\"issuer\":\"https://login.microsoftonline.com/{tenantid}/v2.0\",\"jwks_uri\":\"https://login.microsoftonline.com/common/discovery/v2.0/keys\"}")])
        let callbackURL = URL(string: query["redirect_uri"]!)!
        let callback = Data("GET /callback?code=c&state=\(query["state"]!) HTTP/1.1\r\nHost: 127.0.0.1:\(callbackURL.port!)\r\n\r\n".utf8)
        do { try await worker.completeAuthorization(accountID: teamsTestContext.accountID, callback: callback); XCTFail("Grant bypassed active refresh owner") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .operationBusy) }
        let stored = try await vault.load(accountID: teamsTestContext.accountID)
        XCTAssertEqual(stored, original)
        try await worker.cancelAuthorization(accountID: teamsTestContext.accountID)
        await http.set("/v1.0/me", responses: [teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Test User\"}")])
        await http.release(teamsJSON("{\"access_token\":\"refreshed-old-session\",\"expires_in\":3600,\"token_type\":\"Bearer\",\"scope\":\"Chat.Read User.Read\"}"))
        let refreshed = try await refreshing.value; XCTAssertEqual(refreshed, "refreshed-old-session")
        let final = try await vault.load(accountID: teamsTestContext.accountID)
        XCTAssertEqual(final?.accessToken, "refreshed-old-session")
        await session.close(); await second.close(); await worker.shutdown()
    }

    func testRefreshIsSingleOwnerAcrossRepositories() async throws {
        let db = try database(), first = try await teamsTestRepository(db)
        let second = TeamsRepository(keyProvider: teamsTestKey)
        try await second.open(configuration: db.configuration)
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        let old = bundle(expired: true)
        try await vault.save(old, accountID: teamsTestContext.accountID)
        let http = TeamsRoutedHTTP(["/v1.0/me": [teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Test User\",\"mail\":null}")]])
        let pinned = TeamsOAuthConfiguration(clientID: oauthConfiguration.clientID, authority: teamsTestContext.principal.tenantID)
        await http.hold("/\(pinned.authority)/oauth2/v2.0/token")
        let one = TeamsSession(context: teamsTestContext, configuration: pinned, repository: first, vault: vault, transport: http)
        let two = TeamsSession(context: teamsTestContext, configuration: pinned, repository: second, vault: vault, transport: http)
        let refreshing = Task { try await one.token() }
        await http.waitForHeldRequest()
        do { _ = try await two.token(); XCTFail("Concurrent refresh") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .operationBusy) }
        await http.release(teamsJSON("{\"access_token\":\"fresh\",\"expires_in\":3600,\"token_type\":\"Bearer\",\"scope\":\"Chat.Read User.Read\"}"))
        let firstToken = try await refreshing.value
        let secondToken = try await two.token()
        XCTAssertEqual(firstToken, "fresh")
        XCTAssertEqual(secondToken, "fresh")
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/token") == true }.count, 1)
        await one.close(); await two.close()
        await first.close(); await second.close()
    }

    func testShutdownDoesNotPublishOrReadOtherAccounts() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        try await vault.save(bundle(), accountID: teamsTestContext.accountID)
        let http = TeamsRoutedHTTP([:]); await http.hold("/v1.0/me")
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        let connecting = Task { try await worker.connect(accountID: teamsTestContext.accountID) }
        await http.waitForHeldRequest()
        await worker.shutdown()
        await http.release(teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Test User\",\"mail\":null}"))
        do { try await connecting.value; XCTFail("Shutdown result published") } catch is CancellationError {}
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1.0/me"])
    }

    func testCancelDuringDeviceChallengeCannotInstallLatePrompt() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let http = TeamsRoutedHTTP([:]); await http.hold("/organizations/oauth2/v2.0/devicecode")
        let worker = TeamsWorker(repository: repository, transport: http, vault: TeamsTokenVault(api: TeamsFakeKeychain()), automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        let starting = Task { try await worker.beginAuthorization(accountID: teamsTestContext.accountID, method: .deviceCode, capabilities: [.basicChats]) }
        await http.waitForHeldRequest()
        try await worker.cancelAuthorization(accountID: teamsTestContext.accountID)
        await http.release(teamsJSON("{\"device_code\":\"private\",\"user_code\":\"TEST-CODE\",\"verification_uri\":\"https://microsoft.com/devicelogin\",\"expires_in\":100,\"interval\":5}"))
        do { _ = try await starting.value; XCTFail("Cancelled prompt installed") } catch is CancellationError {}
        let status = try await worker.authorizationStatus(accountID: teamsTestContext.accountID)
        if case .cancelled = status {} else { XCTFail("Late grant status published") }
        await worker.shutdown()
    }

    func testShutdownRejectsPendingRefreshBeforeIdentityOrCredentialWrite() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        let original = bundle(expired: true)
        try await vault.save(original, accountID: teamsTestContext.accountID)
        let http = TeamsRoutedHTTP(["/v1.0/me": [teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Test User\",\"mail\":null}")]])
        await http.hold("/\(teamsTestContext.principal.tenantID)/oauth2/v2.0/token")
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        let connecting = Task { try await worker.connect(accountID: teamsTestContext.accountID) }
        await http.waitForHeldRequest()
        await worker.shutdown()
        await http.release(teamsJSON("{\"access_token\":\"late-refresh\",\"expires_in\":3600,\"token_type\":\"Bearer\",\"scope\":\"Chat.Read User.Read\"}"))
        do { try await connecting.value; XCTFail("Shutdown refresh published") } catch is CancellationError {}
        let stored = try await vault.load(accountID: teamsTestContext.accountID)
        XCTAssertEqual(stored, original)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testHugeCooldownUsesBoundedCancellableWaitWithoutEarlyRetry() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        try await vault.save(bundle(), accountID: teamsTestContext.accountID)
        let http = TeamsRoutedHTTP([
            "/v1.0/me": [teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Test User\",\"mail\":null}")],
            "/v1.0/me/chats": [teamsJSON("{\"value\":[{\"id\":\"a\",\"chatType\":\"oneOnOne\"}]}")],
            "/v1.0/chats/a/messages": [teamsJSON("{}", status: 429, headers: ["Retry-After": "1e100"])]
        ])
        let clock = TeamsStopClock()
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: true, pollingClock: clock)
        _ = try await worker.load(configuration: db.configuration)
        try await worker.connect(accountID: teamsTestContext.accountID)
        let interval = await clock.observed()
        XCTAssertEqual(interval, 3600)
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/messages") == true }.count, 1)
        await worker.shutdown()
    }
}
