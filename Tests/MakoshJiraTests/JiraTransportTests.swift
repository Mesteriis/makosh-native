import Foundation
import XCTest
@testable import MakoshJira

final class JiraTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        JiraStubProtocol.reset([])
    }

    func testBasicAuthorizationHeaderIsSet() async throws {
        JiraStubProtocol.reset([.json("{}")])
        _ = try await JiraTestSupport.transport().send(JiraRequest(path: "/rest/api/3/myself"))
        let request = try XCTUnwrap(JiraStubProtocol.recorded.first)
        let expected = "Basic " + Data("me@example.com:secret-token".utf8).base64EncodedString()
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expected)
        XCTAssertEqual(request.url?.absoluteString, "https://jira.test/rest/api/3/myself")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testRateLimitedCarriesRetryAfterSeconds() async throws {
        JiraStubProtocol.reset([.json(#"{"errorMessages":["slow down"]}"#, status: 429, headers: ["Retry-After": "7"])])
        do {
            _ = try await JiraTestSupport.transport().send(JiraRequest(path: "/rest/api/3/myself"))
            XCTFail("429 must throw")
        } catch let error as JiraAdapterError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 7))
        }
        JiraStubProtocol.reset([.json("{}", status: 503)])
        do {
            _ = try await JiraTestSupport.transport().send(JiraRequest(path: "/rest/api/3/myself"))
            XCTFail("503 must throw")
        } catch let error as JiraAdapterError {
            XCTAssertEqual(error, .rateLimited(retryAfter: nil))
        }
    }

    func testErrorBodyIsNeverInTheError() async throws {
        JiraStubProtocol.reset([.json(#"{"errorMessages":["secret-body"]}"#, status: 403)])
        do {
            _ = try await JiraTestSupport.transport().send(JiraRequest(path: "/rest/api/3/myself"))
            XCTFail("403 must throw")
        } catch {
            let text = String(describing: error) + String(reflecting: error)
            XCTAssertFalse(text.contains("secret-body"))
            XCTAssertFalse(text.contains("secret-token"))
            XCTAssertEqual(error as? JiraAdapterError, .unauthorized)
        }
        XCTAssertFalse(String(describing: JiraTestSupport.credential).contains("secret-token"))
        XCTAssertFalse(String(reflecting: JiraTestSupport.transport()).contains("secret-token"))
    }

    func testInvalidCursorMessageMapsToInvalidCursor() async throws {
        let body = #"{"errorMessages":["The provided next page token is invalid or expired."],"errors":{}}"#
        JiraStubProtocol.reset([.json(body, status: 400)])
        let request = JiraRequest(
            path: "/rest/api/3/search/jql", method: .post, body: Data(#"{"jql":"x","nextPageToken":"tok"}"#.utf8))
        do {
            _ = try await JiraTestSupport.transport().send(request)
            XCTFail("400 must throw")
        } catch let error as JiraAdapterError {
            XCTAssertEqual(error, .invalidCursor)
        }
        JiraStubProtocol.reset([.json(#"{"errorMessages":["something else"]}"#, status: 400)])
        do {
            _ = try await JiraTestSupport.transport().send(request)
            XCTFail("400 must throw")
        } catch let error as JiraAdapterError {
            XCTAssertEqual(error, .http(status: 400))
        }
    }

    func testTransportFailuresAreCodesOnly() async throws {
        JiraStubProtocol.reset([JiraStubProtocol.Reply(fail: .timedOut)])
        do {
            _ = try await JiraTestSupport.transport().send(JiraRequest(path: "/rest/api/3/myself"))
            XCTFail("timeout must throw")
        } catch let error as JiraAdapterError {
            XCTAssertEqual(error, .transport(code: "timedOut"))
        }
    }
}
