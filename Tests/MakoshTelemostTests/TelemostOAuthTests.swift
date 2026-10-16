import XCTest
import CryptoKit
@testable import MakoshTelemost

let telemostTokenFixture = #"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","token_type":"bearer","expires_in":3600}"#
let telemostUserFixture = #"{"id":"synthetic-user","client_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","login":"Synthetic"}"#

func telemostCallback(_ request: TelemostAuthorizationRequest, code: String = "1234567") throws -> URL {
    let state = try XCTUnwrap(URLComponents(url: request.authURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
    var parts = try XCTUnwrap(URLComponents(url: request.expectedCallback, resolvingAgainstBaseURL: false))
    parts.queryItems = [.init(name: "code", value: code), .init(name: "state", value: state)]
    return try XCTUnwrap(parts.url)
}
actor TelemostPausedUserInfo: TelemostHTTPTransport {
    var pending: CheckedContinuation<TelemostHTTPResponse, any Error>?
    var requested = false
    var observer: CheckedContinuation<Void, Never>?
    func response(to request: URLRequest) async throws -> TelemostHTTPResponse {
        if request.url?.host == "oauth.yandex.ru" { return telemostJSON(telemostTokenFixture) }
        requested = true; observer?.resume(); observer = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func wait() async { if requested { return }; await withCheckedContinuation { observer = $0 } }
    func finish() { pending?.resume(returning: telemostJSON(telemostUserFixture)); pending = nil }
}

final class TelemostMutableDate: @unchecked Sendable {
    let lock = NSLock()
    var value = Date(timeIntervalSince1970: 0)
    func now() -> Date { lock.withLock { value } }
    func advance() { lock.withLock { value = Date(timeIntervalSince1970: 1000) } }
}
@MainActor
final class TelemostOAuthTests: XCTestCase {
    func testPKCESingleUseExactCallbackAndExpiry() async throws {
        let http = TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture)])
        let oauth = TelemostOAuth(transport: http)
        let request = try await oauth.begin(account: telemostTestAccount, mode: .browserCallback)
        let auth = try XCTUnwrap(URLComponents(url: request.authURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(auth.host, "oauth.yandex.ru")
        XCTAssertEqual(auth.queryItems?.first { $0.name == "code_challenge_method" }?.value, "S256")
        var bad = try XCTUnwrap(URLComponents(url: telemostCallback(request), resolvingAgainstBaseURL: false)); bad.host = "wrong"
        do { _ = try await oauth.complete(id: request.id, callback: bad.url!); XCTFail("wrong callback accepted") } catch {}
        let granted = try await oauth.complete(id: request.id, callback: telemostCallback(request))
        XCTAssertEqual(granted.principal.userID, "synthetic-user")
        let requests = await http.requests
        let form = try XCTUnwrap(URLComponents(string: "https://fixture.invalid/?" + String(data: requests[0].httpBody!, encoding: .utf8)!)?.queryItems)
        let verifier = try XCTUnwrap(form.first { $0.name == "code_verifier" }?.value)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(auth.queryItems?.first { $0.name == "code_challenge" }?.value, challenge)
        XCTAssertFalse(form.contains { $0.name == "client_secret" })
        XCTAssertEqual(requests[1].url?.absoluteString, "https://login.yandex.ru/info?format=json")
        XCTAssertNil(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "oauth_token" })
        do { _ = try await oauth.complete(id: request.id, callback: telemostCallback(request)); XCTFail("grant replay") } catch {}
    }
    func testManualCodeRequiresExplicitMode() async throws {
        let http = TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture)])
        let oauth = TelemostOAuth(transport: http)
        let request = try await oauth.begin(account: telemostTestAccount, mode: .manualCode)
        XCTAssertEqual(request.expectedCallback.absoluteString, "https://oauth.yandex.ru/verification_code")
        do { _ = try await oauth.complete(id: request.id, code: "bad"); XCTFail("invalid code") } catch {}
        let grant = try await oauth.complete(id: request.id, code: "1234567")
        XCTAssertEqual(grant.token.accessToken, "synthetic-access")
        let callbackOnly = try await oauth.begin(account: telemostTestAccount, mode: .browserCallback)
        do { _ = try await oauth.complete(id: callbackOnly.id, code: "1234567"); XCTFail("hidden manual fallback") } catch {}
    }
    func testNoExchangeRetryOrSecretsInURL() async throws {
        let http = TelemostScriptedHTTP([telemostJSON("{}", status: 503), telemostJSON(telemostTokenFixture)])
        let oauth = TelemostOAuth(transport: http)
        let request = try await oauth.begin(account: telemostTestAccount, mode: .browserCallback)
        do { _ = try await oauth.complete(id: request.id, callback: telemostCallback(request)); XCTFail("failure accepted") } catch {}
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://oauth.yandex.ru/token")
    }
    func testReducedScopeAndVerifiedPrincipal() async throws {
        let narrow = #"{"access_token":"synthetic","token_type":"bearer","expires_in":3600,"scope":"telemost-api:conferences.read"}"#
        let http = TelemostScriptedHTTP([telemostJSON(narrow), telemostJSON(telemostUserFixture)])
        let oauth = TelemostOAuth(transport: http)
        let request = try await oauth.begin(account: telemostTestAccount, mode: .browserCallback)
        let grant = try await oauth.complete(id: request.id, callback: telemostCallback(request))
        XCTAssertEqual(grant.token.capabilities, [.read])
        let wrong = telemostUserFixture.replacingOccurrences(of: String(repeating: "a", count: 32), with: String(repeating: "b", count: 32))
        let other = TelemostOAuth(transport: TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(wrong)]))
        let pending = try await other.begin(account: telemostTestAccount, mode: .browserCallback)
        do { _ = try await other.complete(id: pending.id, callback: telemostCallback(pending)); XCTFail("different client accepted") } catch {}
    }
    func testCancelledUserInfoCannotInstallToken() async throws {
        let http = TelemostPausedUserInfo(), oauth = TelemostOAuth(transport: http)
        let request = try await oauth.begin(account: telemostTestAccount, mode: .browserCallback)
        let callback = try telemostCallback(request)
        let completion = Task { try await oauth.complete(id: request.id, callback: callback) }
        await http.wait(); await oauth.cancel(id: request.id); await http.finish()
        do { _ = try await completion.value; XCTFail("cancelled grant returned") } catch {}
        do { _ = try await oauth.consumeGrant(id: request.id, accountID: request.accountID); XCTFail("cancelled grant available") } catch {}
    }
    func testExpiryRequiresLoginWithoutRefresh() async throws {
        let http = TelemostScriptedHTTP([])
        let date = TelemostMutableDate(), oauth = TelemostOAuth(transport: http, now: { date.now() })
        let request = try await oauth.begin(account: telemostTestAccount, mode: .browserCallback)
        date.advance()
        do { _ = try await oauth.complete(id: request.id, callback: telemostCallback(request)); XCTFail("expired grant") }
        catch { XCTAssertEqual(error as? TelemostFailure, .expired) }
        let requests = await http.requests; XCTAssertTrue(requests.isEmpty)
    }
}
