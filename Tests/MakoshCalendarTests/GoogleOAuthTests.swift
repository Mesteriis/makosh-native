import CryptoKit
import Foundation
import XCTest
@testable import MakoshCalendar

final class GoogleOAuthTests: XCTestCase {
    private let client = GoogleOAuthClient(clientID: "client-1.apps.googleusercontent.com", clientSecret: "secret-1")

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static let idToken = "eyJhbGciOiJSUzI1NiJ9." + base64URL(Data(#"{"sub":"10001","email":"me@gmail.test"}"#.utf8)) + ".sig"

    /// A browser that follows the authorization URL straight to the loopback redirect.
    private func browser(query: @escaping @Sendable (URLComponents) -> String) -> @Sendable (URL) -> Void {
        { url in
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let redirect = components.queryItems!.first { $0.name == "redirect_uri" }!.value!
            let target = URL(string: redirect + "?" + query(components))!
            Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: target) }
        }
    }
    private static func state(_ c: URLComponents) -> String { c.queryItems!.first { $0.name == "state" }!.value! }

    private func tokenReply(_ body: String, status: Int = 200) {
        StubURLProtocol.install { _ in .init(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8)) }
    }

    func testSignInExchangesCodeWithPKCEAndReadsSubject() async throws {
        tokenReply(
            #"{"access_token":"at-1","expires_in":3600,"refresh_token":"rt-1","scope":"openid email https://www.googleapis.com/auth/calendar","id_token":"\#(Self.idToken)"}"#
        )
        let challenge = LockedBox<String?>(nil)
        let oauth = GoogleOAuth(
            client: client, http: StubURLProtocol.http(),
            openBrowser: browser { components in
                challenge.set(components.queryItems!.first { $0.name == "code_challenge" }?.value)
                XCTAssertEqual(components.host, "accounts.google.com")
                let names = Set(components.queryItems!.map(\.name))
                XCTAssertTrue(names.isSuperset(of: ["client_id", "redirect_uri", "code_challenge", "state", "scope", "access_type"]))
                return "code=auth-code&state=\(Self.state(components))"
            }, timeout: 10)
        let grant = try await oauth.signIn(loginHint: "me@gmail.test")
        XCTAssertEqual(grant.subject, "10001")
        XCTAssertEqual(grant.email, "me@gmail.test")
        XCTAssertEqual(grant.refreshToken, "rt-1")
        XCTAssertTrue(grant.scopes.contains("https://www.googleapis.com/auth/calendar"))
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let verifier = try XCTUnwrap(URLComponents(string: "?" + body)?.queryItems?.first { $0.name == "code_verifier" }?.value)
        XCTAssertEqual(Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))), challenge.get())
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=auth-code"))
        let token = try await oauth.accessToken(for: grant)
        XCTAssertEqual(token.value, "at-1")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "the fresh access token is cached")
    }

    func testStateMismatchIsIgnoredUntilTimeout() async {
        tokenReply("{}")
        let oauth = GoogleOAuth(
            client: client, http: StubURLProtocol.http(), openBrowser: browser { _ in "code=x&state=forged" }, timeout: 0.7)
        do {
            _ = try await oauth.signIn(loginHint: nil)
            XCTFail("a forged state must not sign in")
        } catch { XCTAssertEqual(error as? CalendarFailure, .signInRequired) }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testListenerClosedOnTimeout() async throws {
        let redirect = LockedBox<String?>(nil)
        let oauth = GoogleOAuth(
            client: client, http: StubURLProtocol.http(),
            openBrowser: { url in
                redirect.set(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_uri" }!.value)
            }, timeout: 0.3)
        _ = try? await oauth.signIn(loginHint: nil)
        let target = try XCTUnwrap(redirect.get().flatMap(URL.init(string:)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        do {
            _ = try await URLSession(configuration: configuration).data(from: target)
            XCTFail("the loopback listener must be closed")
        } catch {}
    }

    func testAdminPolicyMapsToAdminBlocked() async {
        for code in ["admin_policy_enforced", "org_internal", "access_denied"] {
            tokenReply("{}")
            let oauth = GoogleOAuth(
                client: client, http: StubURLProtocol.http(), openBrowser: browser { "error=\(code)&state=\(Self.state($0))" }, timeout: 10)
            do {
                _ = try await oauth.signIn(loginHint: nil)
                XCTFail("consent error must fail")
            } catch { XCTAssertEqual(error as? CalendarFailure, .adminBlocked, code) }
        }
    }

    func testInvalidGrantMapsToSignInRequired() async {
        tokenReply(#"{"error":"invalid_grant","error_description":"secret detail"}"#, status: 400)
        let oauth = GoogleOAuth(client: client, http: StubURLProtocol.http(), openBrowser: { _ in }, timeout: 1)
        do {
            _ = try await oauth.accessToken(for: GoogleGrant(subject: "1", email: "me@gmail.test", scopes: [], refreshToken: "rt"))
            XCTFail("revoked grant must fail")
        } catch { XCTAssertEqual(error as? CalendarFailure, .signInRequired) }
    }

    func testAccessTokenCachedUntilExpiry() async throws {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000_000))
        tokenReply(#"{"access_token":"at-2","expires_in":120}"#)
        let oauth = GoogleOAuth(client: client, http: StubURLProtocol.http(), openBrowser: { _ in }, timeout: 1, now: { clock.get() })
        let grant = GoogleGrant(subject: "1", email: "me@gmail.test", scopes: [], refreshToken: "rt")
        _ = try await oauth.accessToken(for: grant)
        clock.set(clock.get().addingTimeInterval(30))
        _ = try await oauth.accessToken(for: grant)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        clock.set(clock.get().addingTimeInterval(40))  // within 60 s of expiry
        _ = try await oauth.accessToken(for: grant)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertTrue(String(decoding: StubURLProtocol.requests[1].httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token"))
    }
}

/// A tiny lock-protected box for values crossing test closures.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
}
