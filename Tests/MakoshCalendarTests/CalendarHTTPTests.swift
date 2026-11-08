import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarHTTPTests: XCTestCase {
    private let url = URL(string: "https://calendar.test/path?token=secret-query")!

    private func failure(_ reply: StubURLProtocol.Reply) async -> Error? {
        StubURLProtocol.install { _ in reply }
        do {
            _ = try await StubURLProtocol.http().send(URLRequest(url: url), stage: "read")
            return nil
        } catch { return error }
    }

    func testReturnsBodyAndResponse() async throws {
        StubURLProtocol.install { _ in .init(status: 200, body: Data("ok".utf8)) }
        let (data, response) = try await StubURLProtocol.http().send(URLRequest(url: url), stage: "read")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(response.statusCode, 200)
    }

    func testClassifies4xxAsRejectedAnd5xxAsUnknown() async {
        let forbidden = await failure(.init(status: 403, body: Data("secret body".utf8)))
        XCTAssertEqual(forbidden as? CalendarFailure, .rejected(code: 403, stage: "read"))
        let server = await failure(.init(status: 502))
        XCTAssertEqual(server as? CalendarFailure, .unknownOutcome(stage: "read"))
        let timeout = await failure(.init(status: 408))
        XCTAssertEqual(timeout as? CalendarFailure, .unknownOutcome(stage: "read"))
        let conflict = await failure(.init(status: 409))
        XCTAssertEqual(conflict as? CalendarFailure, .unknownOutcome(stage: "read"))
        let dropped = await failure(.init(error: URLError(.networkConnectionLost)))
        XCTAssertEqual(dropped as? CalendarFailure, .unknownOutcome(stage: "read"))
    }

    func testRetryAfterPausesAsUnreachable() async {
        let limited = await failure(.init(status: 429, headers: ["Retry-After": "120"]))
        XCTAssertEqual(limited as? CalendarHTTPError, .retryAfter(120))
        XCTAssertEqual((limited as? CalendarHTTPError)?.failure, .unreachable)
        let unavailable = await failure(.init(status: 503, headers: ["Retry-After": "30"]))
        XCTAssertEqual(unavailable as? CalendarHTTPError, .retryAfter(30))
        let noHeader = await failure(.init(status: 429))
        XCTAssertEqual(noHeader as? CalendarHTTPError, .retryAfter(60))
    }

    func testPreconditionFailedIsItsOwnError() async {
        let stale = await failure(.init(status: 412))
        XCTAssertEqual(stale as? CalendarHTTPError, .preconditionFailed)
    }

    func testCrossHostRedirectRefused() async {
        let redirected = await failure(
            .init(status: 302, headers: ["Location": "https://evil.test/x"], redirect: URL(string: "https://evil.test/x")))
        XCTAssertEqual(redirected as? CalendarFailure, .rejected(code: 302, stage: "read"))
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.host }, ["calendar.test"])
    }

    func testOversizedBodyRejected() async {
        StubURLProtocol.install { _ in .init(status: 200, body: Data(count: 2048)) }
        do {
            _ = try await StubURLProtocol.http().send(URLRequest(url: url), stage: "read", limit: 1024)
            XCTFail("oversized body must be refused")
        } catch { XCTAssertEqual(error as? CalendarFailure, .invalidInput("response too large")) }
    }

    func testErrorsCarryNoBodyOrURL() async {
        let error = await failure(.init(status: 400, body: Data("secret body".utf8)))
        let text = String(describing: error as Any) + String(reflecting: error as Any)
        XCTAssertFalse(text.contains("secret body"))
        XCTAssertFalse(text.contains("secret-query"))
        XCTAssertFalse(text.contains("calendar.test"))
    }
}
