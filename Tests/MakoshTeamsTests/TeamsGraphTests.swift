import XCTest
@testable import MakoshTeams

@MainActor
final class TeamsGraphTests: XCTestCase {
    struct Item: Codable, Sendable { let id: String }

    // Truncating a provider page before storing its nextLink loses m2 permanently.
    func testBoundedPagePreservesOverflowAndBindsContinuation() async throws {
        let transport = TeamsScriptedHTTP([teamsJSON("""
        {"value":[{"id":"m0"},{"id":"m1"},{"id":"m2"}],
         "@odata.nextLink":"https://graph.microsoft.com/v1.0/chats/chat1/messages?$skiptoken=next"}
        """)])
        let collection = TeamsCollection(context: teamsTestContext, kind: .messages(.chat("chat1")))
        let graph = TeamsGraphClient(context: teamsTestContext, transport: transport)
        let page = try await graph.page(Item.self, collection: collection, continuation: nil, token: "synthetic-token", limit: 2)
        XCTAssertEqual(page.values.map(\.id), ["m0", "m1", "m2"])
        XCTAssertEqual(page.next?.owner, collection)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "$top", value: "2")])
    }

    // A cursor must never move an authenticated read to a different principal or collection.
    func testRejectsCrossAccountCursorAndHostBeforeTransport() async throws {
        let transport = TeamsScriptedHTTP([])
        let graph = TeamsGraphClient(context: teamsTestContext, transport: transport)
        let collection = TeamsCollection(context: teamsTestContext, kind: .messages(.chat("chat1")))
        let other = TeamsCollection(context: TeamsAccountContext(accountID: UUID(), principal: teamsTestContext.principal),
                                    kind: .messages(.chat("chat1")))
        let cursors = [
            TeamsContinuation(owner: other, url: URL(string: "https://graph.microsoft.com/v1.0/chats/chat1/messages?$skiptoken=n")!),
            TeamsContinuation(owner: collection, url: URL(string: "https://example.invalid/v1.0/chats/chat1/messages")!),
            TeamsContinuation(owner: collection, url: URL(string: "https://graph.microsoft.com:444/v1.0/chats/chat1/messages")!),
            TeamsContinuation(owner: collection, url: URL(string: "https://graph.microsoft.com/v1.0/chats/chat2/messages")!),
            TeamsContinuation(owner: collection, url: URL(string: "https://user@graph.microsoft.com/v1.0/chats/chat1/messages")!)
        ]
        for cursor in cursors {
            do {
                _ = try await graph.page(Item.self, collection: collection, continuation: cursor, token: "test")
                XCTFail("Unsafe cursor accepted")
            } catch let failure as TeamsFailure { XCTAssertEqual(failure, .invalidContinuation) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    // Opaque Graph IDs containing separators must remain a single encoded path component.
    func testOpaqueIDsCannotEscapePath() async throws {
        let transport = TeamsScriptedHTTP([teamsJSON("{\"value\":[]}")])
        let graph = TeamsGraphClient(context: teamsTestContext, transport: transport)
        let collection = TeamsCollection(context: teamsTestContext, kind: .messages(.chat("19:a/b+%?@thread.v2")))
        _ = try await graph.page(Item.self, collection: collection, continuation: nil, token: "test")
        let requests = await transport.requests
        let url = try XCTUnwrap(requests.first?.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                       "/v1.0/chats/19%3Aa%2Fb%2B%25%3F%40thread.v2/messages")
        for id in ["", ".", ".."] {
            do {
                _ = try await graph.page(Item.self, collection: TeamsCollection(context: teamsTestContext, kind: .messages(.chat(id))),
                                         continuation: nil, token: "test")
                XCTFail("Invalid path component accepted")
            } catch let failure as TeamsFailure { XCTAssertEqual(failure, .invalidResource) }
        }
        let composed = TeamsScope(accountID: teamsTestContext.accountID, tenantID: "t", resource: .chat("\u{00e9}"))
        let decomposed = TeamsScope(accountID: teamsTestContext.accountID, tenantID: "t", resource: .chat("e\u{0301}"))
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertNotEqual(composed.storageKey, decomposed.storageKey)
    }

    // A retry must wait the server's cooldown; a long cooldown is reported, never shortened.
    func testReadRetryHonors429() async throws {
        let transport = TeamsScriptedHTTP([
            teamsJSON("{}", status: 429, headers: ["retry-after": "7"]),
            teamsJSON("{}", status: 503, headers: ["Retry-After": "2"]),
            teamsJSON("{\"value\":[{\"id\":\"ok\"}]}")
        ])
        let clock = TeamsTestDelay()
        let graph = TeamsGraphClient(context: teamsTestContext, transport: transport, retryClock: clock)
        let collection = TeamsCollection(context: teamsTestContext, kind: .chats)
        let page = try await graph.page(Item.self, collection: collection, continuation: nil, token: "test")
        XCTAssertEqual(page.values.map(\.id), ["ok"])
        let intervals = await clock.intervals
        XCTAssertEqual(intervals, [7, 2])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)

        let limited = TeamsScriptedHTTP([teamsJSON("{}", status: 429, headers: ["Retry-After": "3600"])])
        do {
            _ = try await TeamsGraphClient(context: teamsTestContext, transport: limited, retryClock: clock)
                .page(Item.self, collection: collection, continuation: nil, token: "test")
            XCTFail("Long cooldown ignored")
        } catch let failure as TeamsFailure { XCTAssertEqual(failure, .throttled(retryAfter: 3600)) }
        let limitedRequests = await limited.requests
        XCTAssertEqual(limitedRequests.count, 1)
    }

    // The real URLSession delegate bounds incoming chunks and refuses redirects before following them.
    func testStreamingJSONLimitAndRedirectRejection() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamsURLProtocol.self]
        let transport = TeamsURLSessionTransport(configuration: configuration)
        for (path, expected) in [("large", TeamsFailure.bodyTooLarge), ("redirect", .redirectRejected)] {
            do {
                _ = try await transport.response(to: URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/" + path)!))
                XCTFail("Unsafe response accepted")
            } catch let failure as TeamsFailure { XCTAssertEqual(failure, expected) }
        }
    }

    // A looping cursor must stop the scan while keeping the received page for the durable journal.
    func testCycleKeepsReceivedValuesAndReportsIncompleteScan() async throws {
        let transport = TeamsScriptedHTTP([
            teamsJSON("{\"value\":[{\"id\":\"a\"}],\"@odata.nextLink\":\"https://graph.microsoft.com/v1.0/me/chats?$skiptoken=n\"}"),
            teamsJSON("{\"value\":[{\"id\":\"b\"}],\"@odata.nextLink\":\"https://graph.microsoft.com/v1.0/me/chats?$skiptoken=n\"}")
        ])
        let graph = TeamsGraphClient(context: teamsTestContext, transport: transport)
        let collection = TeamsCollection(context: teamsTestContext, kind: .chats)
        let first = try await graph.page(Item.self, collection: collection, continuation: nil, token: "test")
        let second = try await graph.page(Item.self, collection: collection, continuation: first.next, token: "test")
        XCTAssertEqual(second.values.map(\.id), ["b"])
        XCTAssertNil(second.next)
        XCTAssertEqual(second.continuationFailure, .invalidContinuation)
    }

    // /me's user ID must never be mistaken for a tenant identifier.
    func testIdentityReadsUserAndPreservesForbidden() async throws {
        let transport = TeamsScriptedHTTP([
            teamsJSON("{\"id\":\"user1\",\"displayName\":\"Test User\",\"mail\":null}"),
            teamsJSON("{\"error\":{\"code\":\"Forbidden\"}}", status: 403)
        ])
        let graph = TeamsGraphClient(context: teamsTestContext, transport: transport)
        let user = try await graph.identity(token: "test")
        XCTAssertEqual(user.id, "user1")
        do { _ = try await graph.identity(token: "test"); XCTFail("Forbidden read accepted") }
        catch let failure as TeamsFailure { XCTAssertEqual(failure, .forbidden) }
    }

    func testCatalogueEndpointsDoNotReceiveUnsupportedTopParameter() async throws {
        let http = TeamsScriptedHTTP([teamsJSON("{\"value\":[]}"), teamsJSON("{\"value\":[]}"), teamsJSON("{\"value\":[]}")])
        let graph = TeamsGraphClient(context: teamsTestContext, transport: http)
        for kind in [TeamsCollection.Kind.joinedTeams, .channels("team"), .members(.chat("chat"))] {
            _ = try await graph.page(Item.self, collection: TeamsCollection(context: teamsTestContext, kind: kind), continuation: nil, token: "synthetic")
        }
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url?.query }, [nil, nil, nil])
    }
}
