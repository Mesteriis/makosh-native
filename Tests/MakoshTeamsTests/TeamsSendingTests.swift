import XCTest
import MakoshCore
@testable import MakoshTeams

@MainActor
final class TeamsSendingTests: XCTestCase {
    func database() throws -> TeamsTestDatabase { let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }; return db }
    func connected(_ repository: TeamsRepository, db: TeamsTestDatabase, http: any TeamsHTTPTransport, scopes: Set<String>) async throws -> TeamsWorker {
        let vault = TeamsTokenVault(api: TeamsFakeKeychain())
        try await vault.save(TeamsTokenBundle(accessToken: "synthetic", refreshToken: "refresh", idToken: nil, expiresAt: Date().addingTimeInterval(3600), grantedScopes: scopes, expectedNonce: nil), accountID: teamsTestContext.accountID)
        let worker = TeamsWorker(repository: repository, transport: http, vault: vault, automaticSync: false)
        _ = try await worker.load(configuration: db.configuration)
        try await worker.connect(accountID: teamsTestContext.accountID)
        return worker
    }
    var me: TeamsHTTPResponse { teamsJSON("{\"id\":\"\(teamsTestContext.principal.userID)\",\"displayName\":\"Test User\",\"mail\":null}") }
    func testLost201BodyPersistsUnknownAndReconnectNeverReplays() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let http = TeamsRoutedHTTP(["/v1.0/me": [me, me], "/v1.0/chats/test-chat/messages": [teamsJSON("", status: 201)]])
        let worker = try await connected(repository, db: db, http: http, scopes: ["User.Read", "Chat.Read", "ChatMessage.Send"])
        let outgoing = try await worker.send(scope: teamsTestScope, content: TeamsDraft(text: "captured before POST"))
        XCTAssertEqual(outgoing.state, .unknown)
        try await worker.disconnect(accountID: teamsTestContext.accountID)
        try await worker.connect(accountID: teamsTestContext.accountID)
        do { _ = try await worker.resumeOutgoing(accountID: teamsTestContext.accountID, id: outgoing.id); XCTFail("Unknown replayed") }
        catch let error as TeamsFailure { XCTAssertEqual(error, .uncertainSubmission) }
        let page = try await worker.outgoingPage(accountID: teamsTestContext.accountID, before: nil)
        XCTAssertEqual(page.values.first?.state, .unknown)
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        await worker.shutdown()
        let reopened = TeamsRepository(keyProvider: teamsTestKey); try await reopened.open(configuration: db.configuration)
        let restored = try await reopened.outgoing(id: outgoing.id, accountID: teamsTestContext.accountID)
        XCTAssertEqual(restored.state, .unknown)
        await reopened.close()
    }
    func testChannelReplyUsesCapturedRootAndChatSendUsesChatScope() async throws {
        let http = TeamsScriptedHTTP([
            teamsJSON("{\"id\":\"reply\",\"replyToId\":\"root/a\",\"body\":{\"contentType\":\"text\",\"content\":\"reply text\"}}", status: 201),
            teamsJSON("{\"id\":\"chat-message\",\"body\":{\"contentType\":\"text\",\"content\":\"chat text\"}}", status: 201)
        ])
        let graph = TeamsGraphClient(context: teamsTestContext, transport: http)
        let thread = TeamsScope(accountID: teamsTestContext.accountID, tenantID: teamsTestContext.principal.tenantID, resource: .thread(teamID: "team", channelID: "channel", rootID: "root/a"))
        let reply = try await graph.postMessage(scope: thread, content: TeamsDraft(text: "reply text"), token: "synthetic")
        let chat = try await graph.postMessage(scope: teamsTestScope, content: TeamsDraft(text: "chat text"), token: "synthetic")
        XCTAssertEqual(reply.scope, thread); XCTAssertEqual(chat.scope, teamsTestScope)
        let requests = await http.requests
        XCTAssertEqual(requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath },
            ["/v1.0/teams/team/channels/channel/messages/root%2Fa/replies", "/v1.0/chats/test-chat/messages"])
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(requests.first?.httpBody)) as? [String: [String: String]]
        XCTAssertEqual(json?["body"]?["content"], "reply text")
    }
    func testMutation429NeverRetries() async throws {
        let http = TeamsScriptedHTTP([teamsJSON("{}", status: 429, headers: ["Retry-After": "1"])])
        do {
            _ = try await TeamsGraphClient(context: teamsTestContext, transport: http).postMessage(scope: teamsTestScope, content: TeamsDraft(text: "only once"), token: "synthetic")
            XCTFail("Rejected mutation accepted")
        } catch let error as TeamsFailure { XCTAssertEqual(error, .server(status: 429)) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testReadOnlyAndMissingSendConsentBlockBeforeAdmission() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let http = TeamsRoutedHTTP(["/v1.0/me": [me]])
        let worker = try await connected(repository, db: db, http: http, scopes: ["User.Read", "Chat.Read"])
        do { _ = try await worker.send(scope: teamsTestScope, content: TeamsDraft(text: "blocked")); XCTFail("Missing consent ignored") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .forbidden) }
        let account = try await repository.accounts()[0]
        try await repository.saveAccount(TeamsAccount(id: account.id, name: account.name, clientID: account.clientID, authority: account.authority, verifiedPrincipal: account.verifiedPrincipal, readOnly: true))
        do { _ = try await repository.prepareOutgoing(scope: teamsTestScope, content: TeamsDraft(text: "blocked readonly")); XCTFail("Read-only bypass") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .forbidden) }
        let page = try await repository.outgoingPage(accountID: account.id, before: nil, limit: 50)
        XCTAssertTrue(page.values.isEmpty)
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 0)
        await worker.shutdown()
    }

    func testOversizeMutationIsRejectedBeforeTransport() async throws {
        let http = TeamsScriptedHTTP([])
        do {
            _ = try await TeamsGraphClient(context: teamsTestContext, transport: http).postMessage(scope: teamsTestScope,
                content: TeamsDraft(text: String(repeating: "x", count: 1024 * 1024 + 1)), token: "synthetic")
            XCTFail("Oversize mutation admitted")
        } catch let failure as TeamsFailure { XCTAssertEqual(failure, .invalidResource) }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testDisconnectAfterDispatchStillRetainsKnownReceiptForCapturedAttempt() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let http = TeamsRoutedHTTP(["/v1.0/me": [me]])
        await http.hold("/v1.0/chats/test-chat/messages")
        let worker = try await connected(repository, db: db, http: http, scopes: ["User.Read", "Chat.Read", "ChatMessage.Send"])
        let sending = Task { try await worker.send(scope: teamsTestScope, content: TeamsDraft(text: "captured before disconnect")) }
        await http.waitForHeldRequest()
        try await worker.disconnect(accountID: teamsTestContext.accountID)
        await http.release(teamsJSON("{\"id\":\"accepted-after-disconnect\",\"body\":{\"contentType\":\"text\",\"content\":\"captured before disconnect\"}}", status: 201))
        do { _ = try await sending.value; XCTFail("Obsolete UI result published") } catch is CancellationError {}
        let page = try await repository.outgoingPage(accountID: teamsTestContext.accountID, before: nil, limit: 50)
        XCTAssertEqual(page.values.first?.state, .accepted)
        XCTAssertEqual(page.values.first?.receipt?.providerMessageID, "accepted-after-disconnect")
        let jobs = try await repository.pendingProjection(limit: 50)
        XCTAssertEqual(jobs.first?.observation.identity.messageID, "accepted-after-disconnect")
        await worker.shutdown()
    }

    func testShutdownWaitsForAdmittedReceiptBeforeClosingJournal() async throws {
        let db = try database(), repository = try await teamsTestRepository(db)
        let http = TeamsRoutedHTTP(["/v1.0/me": [me]])
        await http.hold("/v1.0/chats/test-chat/messages")
        let worker = try await connected(repository, db: db, http: http, scopes: ["User.Read", "Chat.Read", "ChatMessage.Send"])
        let sending = Task { try await worker.send(scope: teamsTestScope, content: TeamsDraft(text: "durable during shutdown")) }
        await http.waitForHeldRequest()
        let stopping = Task { await worker.shutdown() }
        // Let shutdown revoke publication, while its admitted mutation still owns the journal connection.
        var stopped = false
        for _ in 0..<100 {
            do { _ = try await worker.authorizationStatus(accountID: teamsTestContext.accountID) }
            catch is CancellationError { stopped = true; break }
            await Task.yield()
        }
        XCTAssertTrue(stopped)
        await http.release(teamsJSON("{\"id\":\"known-during-shutdown\",\"body\":{\"contentType\":\"text\",\"content\":\"durable during shutdown\"}}", status: 201))
        do { _ = try await sending.value; XCTFail("Stopped result published") } catch is CancellationError {} catch {}
        await stopping.value
        let reopened = TeamsRepository(keyProvider: teamsTestKey); try await reopened.open(configuration: db.configuration)
        let page = try await reopened.outgoingPage(accountID: teamsTestContext.accountID, before: nil, limit: 50)
        XCTAssertEqual(page.values.first?.state, .accepted)
        XCTAssertEqual(page.values.first?.receipt?.providerMessageID, "known-during-shutdown")
        let jobs = try await reopened.pendingProjection(limit: 50)
        XCTAssertEqual(jobs.first?.observation.identity.messageID, "known-during-shutdown")
        await reopened.close()
    }
}
