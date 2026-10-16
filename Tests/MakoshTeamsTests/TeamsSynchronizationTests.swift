import XCTest
import MakoshCore
@testable import MakoshTeams

actor TeamsRoutedHTTP: TeamsHTTPTransport {
    var routes: [String: [TeamsHTTPResponse]]
    private(set) var requests: [URLRequest] = []
    private var heldPath: String?
    private var held: CheckedContinuation<TeamsHTTPResponse, any Error>?
    private var observer: CheckedContinuation<Void, Never>?
    init(_ routes: [String: [TeamsHTTPResponse]]) { self.routes = routes }
    func response(to request: URLRequest) async throws -> TeamsHTTPResponse {
        requests.append(request)
        let url = request.url!
        if url.path == heldPath {
            observer?.resume(); observer = nil
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        let route = url.path + (url.query.map { "?" + $0 } ?? "")
        let key = routes[route] != nil ? route : url.path
        guard var responses = routes[key], !responses.isEmpty else { throw TeamsFailure.transport }
        let response = responses.removeFirst(); routes[key] = responses; return response
    }
    func set(_ path: String, responses: [TeamsHTTPResponse]) { routes[path] = responses }
    func hold(_ path: String) { heldPath = path }
    func waitForHeldRequest() async { if held != nil { return }; await withCheckedContinuation { observer = $0 } }
    func release(_ response: TeamsHTTPResponse) { heldPath = nil; held?.resume(returning: response); held = nil }
}

@MainActor
final class TeamsSynchronizationTests: XCTestCase {
    func testDirectChatTitleUsesExpandedOtherMemberWithoutAssumingTenant() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let http = TeamsRoutedHTTP([
            "/v1.0/me/chats": [teamsJSON("""
            {"value":[{"id":"peer","chatType":"oneOnOne","topic":null,"members":[
            {"id":"opaque-self","userId":"22222222-2222-4222-8222-222222222222","displayName":"Me","tenantId":"11111111-1111-4111-8111-111111111111"},
            {"id":"opaque-other","userId":"88888888-8888-4888-8888-888888888888","displayName":"Other User","tenantId":"55555555-5555-4555-8555-555555555555"}]}]}
            """)], "/v1.0/chats/peer/messages": [teamsJSON("{\"value\":[]}")]
        ])
        let sync = TeamsSynchronization(context: teamsTestContext, graph: TeamsGraphClient(context: teamsTestContext, transport: http), repository: repository)
        try await sync.synchronizeCatalogue(token: "synthetic", capabilities: [.basicChats])
        let chats = try await repository.conversations(accountID: teamsTestContext.accountID)
        XCTAssertEqual(chats.first?.displayName, "Other User")
        XCTAssertEqual(chats.first?.members?.last?.tenantID, "55555555-5555-4555-8555-555555555555")
        let requests = await http.requests
        let query = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(URLQueryItem(name: "$expand", value: "members")) ?? false)
    }
    func testExpiredCatalogueCursorRestartsAndPreservesRetainedChats() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let collection = TeamsCollection(context: teamsTestContext, kind: .chats)
        let cursor = TeamsContinuation(owner: collection, url: URL(string: "https://graph.microsoft.com/v1.0/me/chats?$skiptoken=expired")!)
        try await repository.saveConversations([TeamsConversation(scope: teamsTestScope, displayName: "Retained", kind: .oneOnOne)], collection: collection, next: cursor, failure: nil)
        let http = TeamsRoutedHTTP([
            "/v1.0/me/chats?$skiptoken=expired": [teamsJSON("{}", status: 410)],
            "/v1.0/me/chats": [teamsJSON("{\"value\":[{\"id\":\"new-chat\",\"topic\":\"New\",\"chatType\":\"group\"}]}")],
            "/v1.0/chats/test-chat/messages": [teamsJSON("{\"value\":[]}")],
            "/v1.0/chats/new-chat/messages": [teamsJSON("{\"value\":[]}")]
        ])
        let sync = TeamsSynchronization(context: teamsTestContext, graph: TeamsGraphClient(context: teamsTestContext, transport: http), repository: repository)
        try await sync.synchronizeCatalogue(token: "synthetic", capabilities: [.basicChats])
        let chats = try await repository.conversations(accountID: teamsTestContext.accountID)
        XCTAssertEqual(Set(chats.map(\.displayName)), ["Retained", "New"])
        let progress = await sync.progress()
        XCTAssertEqual(progress.restartedCollections, 1)
    }
    func testChatThrottleStopsCatalogueBeforeNextConversation() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let http = TeamsRoutedHTTP([
            "/v1.0/me/chats": [teamsJSON("{\"value\":[{\"id\":\"a\",\"topic\":\"A\",\"chatType\":\"oneOnOne\"},{\"id\":\"b\",\"topic\":\"B\",\"chatType\":\"group\"}]}")],
            "/v1.0/chats/a/messages": [teamsJSON("{}", status: 429, headers: ["Retry-After": "3600"])],
            "/v1.0/chats/b/messages": [teamsJSON("{}", status: 429, headers: ["Retry-After": "3600"])]
        ])
        let sync = TeamsSynchronization(context: teamsTestContext, graph: TeamsGraphClient(context: teamsTestContext, transport: http), repository: repository)
        do { try await sync.synchronizeCatalogue(token: "synthetic", capabilities: [.basicChats]); XCTFail("Cooldown swallowed") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .throttled(retryAfter: 3600)) }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/messages") == true }.count, 1)
        let chats = try await repository.conversations(accountID: teamsTestContext.accountID)
        XCTAssertEqual(chats.count, 2)
    }
    func testResumingRootCursorStillDrainsPreviouslyDiscoveredReplies() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let rootURL = "/v1.0/teams/team/channels/channel/messages"
        let http = TeamsRoutedHTTP([
            rootURL: [teamsJSON("{\"value\":[{\"id\":\"root\",\"body\":{\"contentType\":\"text\",\"content\":\"root\"}}],\"@odata.nextLink\":\"https://graph.microsoft.com/v1.0/teams/team/channels/channel/messages?$skiptoken=second\"}")],
            rootURL + "?$skiptoken=second": [teamsJSON("{\"value\":[]}")],
            rootURL + "/root/replies": [teamsJSON("{}", status: 500), teamsJSON("{\"value\":[{\"id\":\"recovered\",\"replyToId\":\"root\",\"body\":{\"contentType\":\"text\",\"content\":\"saved after restart\"}}]}")]
        ])
        let sync = TeamsSynchronization(context: teamsTestContext, graph: TeamsGraphClient(context: teamsTestContext, transport: http), repository: repository)
        let resource = TeamsResource.channel(teamID: "team", channelID: "channel")
        do { try await sync.scan(resource: resource, token: "synthetic"); XCTFail("Failed reply scan reported complete") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .server(status: 500)) }
        try await sync.scan(resource: resource, token: "synthetic")
        let thread = TeamsScope(accountID: teamsTestContext.accountID, tenantID: teamsTestContext.principal.tenantID,
            resource: .thread(teamID: "team", channelID: "channel", rootID: "root"))
        let replies = try await repository.messages(scope: thread, before: nil, limit: 50)
        XCTAssertEqual(replies.values.map(\.body), ["saved after restart"])
    }
    func testWireFileURLAndRichMetadataAreRetainedWithoutHostedBytes() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let http = TeamsRoutedHTTP(["/v1.0/chats/test-chat/messages": [teamsJSON("""
        {"value":[{"id":"rich","body":{"contentType":"html","content":"<attachment id='file'></attachment>"},
          "attachments":[{"id":"file","name":"test.txt","contentType":"reference","contentUrl":"https://example.sharepoint.com/test.txt"}],
          "reactions":[{"reactionType":"like","user":{"user":{"id":"test"}}}],
          "hostedContents":[{"contentBytes":"MUST-NOT-ENTER-DATABASE"}]}]}
        """)]])
        let sync = TeamsSynchronization(context: teamsTestContext, graph: TeamsGraphClient(context: teamsTestContext, transport: http), repository: repository)
        try await sync.scan(resource: .chat("test-chat"), token: "synthetic")
        let versions = try await repository.versions(scope: teamsTestScope, messageID: "rich", before: nil, limit: 50)
        XCTAssertEqual(versions.first?.message.attachments.first?.contentURL?.absoluteString, "https://example.sharepoint.com/test.txt")
        XCTAssertTrue(versions.first?.message.metadata["reactions"]?.contains("like") ?? false)
        XCTAssertFalse(String(decoding: try XCTUnwrap(versions.first?.observation.sourcePayload), as: UTF8.self).contains("MUST-NOT-ENTER-DATABASE"))
    }
    func testChannelRootsAndAllReplyPagesSurviveReordering() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        let rootURL = "/v1.0/teams/team/channels/channel/messages"
        let replyURL = rootURL + "/root/replies"
        let http = TeamsRoutedHTTP([
            rootURL: [teamsJSON("""
            {"value":[{"id":"root","createdDateTime":"2026-01-01T00:00:00Z","lastModifiedDateTime":"2026-01-01T00:00:00Z","body":{"contentType":"text","content":"old root"},"replies@odata.nextLink":"https://graph.microsoft.com/v1.0/teams/team/channels/channel/messages/root/replies?$skiptoken=expanded"}]}
            """)],
            replyURL: [teamsJSON("{\"value\":[{\"id\":\"reply-old\",\"replyToId\":\"root\",\"body\":{\"contentType\":\"html\",\"content\":\"<b>old reply</b>\"}}],\"@odata.nextLink\":\"https://graph.microsoft.com/v1.0/teams/team/channels/channel/messages/root/replies?$skiptoken=last\"}")],
            replyURL + "?$skiptoken=last": [teamsJSON("{\"value\":[{\"id\":\"reply-new\",\"replyToId\":\"root\",\"body\":{\"contentType\":\"text\",\"content\":\"new reply\"}},{\"id\":\"reply-last-page\",\"replyToId\":\"root\",\"body\":{\"contentType\":\"text\",\"content\":\"last page\"}}]}")]
        ])
        let graph = TeamsGraphClient(context: teamsTestContext, transport: http)
        let sync = TeamsSynchronization(context: teamsTestContext, graph: graph, repository: repository)
        let resource = TeamsResource.channel(teamID: "team", channelID: "channel")
        try await sync.scan(resource: resource, token: "synthetic")
        let thread = TeamsScope(accountID: teamsTestContext.accountID, tenantID: teamsTestContext.principal.tenantID,
            resource: .thread(teamID: "team", channelID: "channel", rootID: "root"))
        let page = try await repository.messages(scope: thread, before: nil, limit: 50)
        XCTAssertEqual(Set(page.values.map(\.id)), ["reply-old", "reply-new", "reply-last-page"])
        let roots = try await repository.messages(scope: TeamsScope(accountID: thread.accountID, tenantID: thread.tenantID, resource: resource), before: nil, limit: 50)
        XCTAssertEqual(roots.values.map(\.id), ["root"])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(page.values.allSatisfy { $0.scope == thread })
    }

    // An expired/invalid cursor restarts safely without replacing the durable notification baseline.
    func testInvalidCursorRestartsScanWithoutMutingNewHistory() async throws {
        let db = try TeamsTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repository = try await teamsTestRepository(db)
        _ = try await repository.commit(page: TeamsPage(values: [teamsTestMessage("retained")], next: nil, continuationFailure: nil), collection: teamsTestCollection, baseline: true)
        let cursor = TeamsContinuation(owner: teamsTestCollection, url: URL(string: "https://graph.microsoft.com/v1.0/chats/test-chat/messages?$skiptoken=expired")!)
        _ = try await repository.commit(page: TeamsPage(values: [], next: cursor, continuationFailure: nil), collection: teamsTestCollection, baseline: false)
        let http = TeamsRoutedHTTP([
            "/v1.0/chats/test-chat/messages?$skiptoken=expired": [teamsJSON("{\"error\":{\"code\":\"InvalidSkipToken\"}}", status: 410)],
            "/v1.0/chats/test-chat/messages": [teamsJSON("{\"value\":[{\"id\":\"m2\",\"body\":{\"contentType\":\"text\",\"content\":\"new after restart\"}}]}")]
        ])
        let sync = TeamsSynchronization(context: teamsTestContext, graph: TeamsGraphClient(context: teamsTestContext, transport: http), repository: repository)
        try await sync.scan(resource: .chat("test-chat"), token: "synthetic")
        let checkpoint = try await repository.checkpoint(collection: teamsTestCollection)
        XCTAssertTrue(checkpoint?.baselineEstablished ?? false)
        XCTAssertTrue(checkpoint?.complete ?? false)
        let versions = try await repository.versions(scope: teamsTestScope, messageID: "m2", before: nil, limit: 50)
        XCTAssertEqual(versions.first?.observation.source, .update)
        let retained = try await repository.messages(scope: teamsTestScope, before: nil, limit: 50)
        XCTAssertEqual(Set(retained.values.map(\.body)), ["retained", "new after restart"])
        let progress = await sync.progress()
        XCTAssertEqual(progress.restartedCollections, 1)
    }
}
