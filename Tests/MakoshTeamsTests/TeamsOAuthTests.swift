import XCTest
import CryptoKit
import Network
@testable import MakoshTeams

@MainActor
final class TeamsOAuthTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let configuration = TeamsOAuthConfiguration(clientID: "44444444-4444-4444-8444-444444444444", authority: "organizations")

    // A bad callback cannot consume the pending challenge, and redemption is single-use.
    func testFragmentedCallbackWrongStateCannotConsumeGrant() async throws {
        let http = TeamsScriptedHTTP([teamsJSON("{\"access_token\":\"opaque\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"token_type\":\"Bearer\",\"scope\":\"User.Read Chat.Read\"}")])
        let client = TeamsOAuthClient(transport: http, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let callback = URL(string: "http://127.0.0.1:41234/callback")!
        let challenge = try await client.beginPKCE(configuration: configuration, capabilities: [.basicChats], callbackURL: callback)
        let components = try XCTUnwrap(URLComponents(url: challenge.authorizationURL, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["code_challenge"], Data(SHA256.hash(data: Data(challenge.verifier.utf8))).teamsBase64URL)
        XCTAssertFalse(challenge.state.isEmpty)
        do {
            _ = try await client.exchange(challenge: challenge, callback: Data("GET /callback?code=c&state=wrong HTTP/1.1\r\nHost: 127.0.0.1:41234\r\n\r\n".utf8))
            XCTFail("Wrong state accepted")
        } catch let error as TeamsFailure { XCTAssertEqual(error, .invalidAuthorization) }
        let before = await http.requests
        XCTAssertTrue(before.isEmpty)
        let request = Data("GET /callback?code=c&state=\(challenge.state) HTTP/1.1\r\nHost: 127.0.0.1:41234\r\n\r\n".utf8)
        let bundle = try await client.exchange(challenge: challenge, callback: request)
        XCTAssertEqual(bundle.accessToken, "opaque")
        do { _ = try await client.exchange(challenge: challenge, callback: request); XCTFail("Replayed grant") }
        catch let error as TeamsFailure { XCTAssertEqual(error, .invalidAuthorization) }
        let sent = await http.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(String(decoding: try XCTUnwrap(sent.first?.httpBody), as: UTF8.self).contains("code_verifier="))
    }

    // slow_down modifies every subsequent interval, including pending responses and local early polls.
    func testDeviceSlowdownPersistsAndExpiryStops() async throws {
        let http = TeamsScriptedHTTP([
            teamsJSON("{\"device_code\":\"private\",\"user_code\":\"TEST-CODE\",\"verification_uri\":\"https://microsoft.com/devicelogin\",\"expires_in\":100,\"interval\":5}"),
            teamsJSON("{\"error\":\"slow_down\"}", status: 400),
            teamsJSON("{\"error\":\"slow_down\"}", status: 400),
            teamsJSON("{\"error\":\"authorization_pending\"}", status: 400)
        ])
        let client = TeamsOAuthClient(transport: http, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let challenge = try await client.beginDevice(configuration: configuration, capabilities: [.basicChats])
        let first = try await client.pollDevice(challenge: challenge, now: now.addingTimeInterval(5))
        XCTAssertEqual(first, .pending(nextPollAt: now.addingTimeInterval(15), interval: 10))
        let early = try await client.pollDevice(challenge: challenge, now: now.addingTimeInterval(6))
        XCTAssertEqual(early, first)
        let second = try await client.pollDevice(challenge: challenge, now: now.addingTimeInterval(15))
        XCTAssertEqual(second, .pending(nextPollAt: now.addingTimeInterval(30), interval: 15))
        let third = try await client.pollDevice(challenge: challenge, now: now.addingTimeInterval(30))
        XCTAssertEqual(third, .pending(nextPollAt: now.addingTimeInterval(45), interval: 15))
        do { _ = try await client.pollDevice(challenge: challenge, now: now.addingTimeInterval(100)); XCTFail("Expired device poll") }
        catch let error as TeamsFailure { XCTAssertEqual(error, .authorizationExpired) }
        let sent = await http.requests
        XCTAssertEqual(sent.count, 4)
    }

    // Refresh rotation is optional; dropping the old token would strand a valid account.
    func testRefreshWithoutReplacementPreservesOldRefreshToken() async throws {
        let http = TeamsScriptedHTTP([teamsJSON("{\"access_token\":\"new-opaque\",\"expires_in\":3600,\"token_type\":\"Bearer\",\"scope\":\"User.Read Chat.Read\"}")])
        let client = TeamsOAuthClient(transport: http, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let original = TeamsTokenBundle(accessToken: "old-opaque", refreshToken: "keep", idToken: nil,
                                       expiresAt: now, grantedScopes: ["User.Read", "Chat.Read"], expectedNonce: nil)
        let refreshed = try await client.refresh(bundle: original, configuration: configuration)
        XCTAssertEqual(refreshed.refreshToken, "keep")
        XCTAssertEqual(refreshed.accessToken, "new-opaque")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    // The real listener must buffer partial headers, ignore unrelated state, and release promptly on cancellation.
    func testLoopbackFragmentationAndCancellation() async throws {
        let listener = TeamsLoopbackAuthorization()
        let url = try await listener.start()
        try await listener.expect(state: "valid-state")
        let received = Task { try await listener.callback() }
        let wrong = try await sendLoopback(url, fragments: ["GET /callback?code=x&state=wrong HTTP/1.1\r\nHost: 127.0.0.1:\(url.port!)\r\n\r\n"])
        XCTAssertTrue(wrong.hasPrefix("HTTP/1.1 400"))
        let response = try await sendLoopback(url, fragments: ["GET /call", "back?code=accepted&state=valid-state HTTP/1.1\r\n", "Host: 127.0.0.1:\(url.port!)\r\n\r\n"])
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        let callback = try await received.value
        XCTAssertEqual(try TeamsLoopbackCallback.parse(callback, callbackURL: url)["code"], "accepted")

        let cancelled = TeamsLoopbackAuthorization()
        _ = try await cancelled.start()
        let waiting = Task { try await cancelled.callback() }
        await cancelled.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled listener survived") }
        catch is CancellationError {}
    }

    func testCancellationRejectsLateCodeExchange() async throws {
        let http = TeamsPausedHTTP()
        let client = TeamsOAuthClient(transport: http)
        let challenge = try await client.beginPKCE(configuration: configuration, capabilities: [.basicChats], callbackURL: URL(string: "http://127.0.0.1:41234/callback")!)
        let request = Data("GET /callback?code=c&state=\(challenge.state) HTTP/1.1\r\nHost: 127.0.0.1:41234\r\n\r\n".utf8)
        let exchanging = Task { try await client.exchange(challenge: challenge, callback: request) }
        await http.waitForRequest()
        await client.cancelPKCE(id: challenge.id)
        await http.complete(teamsJSON("{\"access_token\":\"late\",\"expires_in\":3600,\"token_type\":\"Bearer\"}"))
        do { _ = try await exchanging.value; XCTFail("Cancelled grant published") }
        catch let error as TeamsFailure { XCTAssertEqual(error, .invalidAuthorization) }
    }

    func testMalformedDeviceResponseDoesNotStrandPollingOwner() async throws {
        let http = TeamsScriptedHTTP([
            teamsJSON("{\"device_code\":\"private\",\"user_code\":\"TEST-CODE\",\"verification_uri\":\"https://microsoft.com/devicelogin\",\"expires_in\":100,\"interval\":5}"),
            teamsJSON("not JSON", status: 400), teamsJSON("{\"error\":\"authorization_pending\"}", status: 400)
        ])
        let client = TeamsOAuthClient(transport: http, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let challenge = try await client.beginDevice(configuration: configuration, capabilities: [.basicChats])
        do { _ = try await client.pollDevice(challenge: challenge, now: now.addingTimeInterval(5)); XCTFail("Malformed response accepted") }
        catch let error as TeamsFailure { XCTAssertEqual(error, .invalidResponse) }
        let next = try await client.pollDevice(challenge: challenge, now: now.addingTimeInterval(10))
        XCTAssertEqual(next, .pending(nextPollAt: now.addingTimeInterval(15), interval: 5))
        let sent = await http.requests
        XCTAssertEqual(sent.count, 3)
    }

    func testLoopbackExpiryResumesWaitingCallback() async throws {
        let listener = TeamsLoopbackAuthorization(lifetime: .milliseconds(60))
        _ = try await listener.start()
        try await listener.expect(state: "expected")
        do { _ = try await listener.callback(); XCTFail("Expired listener returned a callback") }
        catch let error as TeamsFailure { XCTAssertEqual(error, .authorizationExpired) }
    }

    private func sendLoopback(_ url: URL, fragments: [String]) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
        defer { connection.cancel() }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: connection.stateUpdateHandler = nil; ready.resume()
                case .failed: connection.stateUpdateHandler = nil; ready.resume(throwing: TeamsFailure.transport)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "makosh.teams.test.loopback"))
        }
        for fragment in fragments {
            try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
                connection.send(content: Data(fragment.utf8), completion: .contentProcessed { error in
                    if error != nil { sent.resume(throwing: TeamsFailure.transport) } else { sent.resume() }
                })
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let data: Data = try await withCheckedThrowingContinuation { received in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if error != nil { received.resume(throwing: TeamsFailure.transport) }
                else { received.resume(returning: data ?? Data()) }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
