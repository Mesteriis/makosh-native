import XCTest
@testable import MakoshTelemost

final class TelemostAPITests: XCTestCase {
    let scope = TelemostScope(accountID: telemostTestAccountID, conferenceID: "123")

    func testMutationBodiesContainOnlyEditedFields() async throws {
        let transport = TelemostScriptedHTTP([telemostJSON(telemostConferenceFixture, status: 201), telemostJSON(telemostConferenceFixture)])
        let api = TelemostAPI(transport: transport)
        _ = try await api.create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins), token: "synthetic-token")
        _ = try await api.update(scope: scope, patch: .init(waitingRoom: .organization), token: "synthetic-token")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "PATCH"])
        XCTAssertEqual(requests.map { $0.url!.absoluteString }, [
            "https://cloud-api.yandex.net/v1/telemost-api/conferences",
            "https://cloud-api.yandex.net/v1/telemost-api/conferences/123"])
        let create = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: String]
        let patch = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: String]
        XCTAssertEqual(create, ["waiting_room_level": "ADMINS"])
        XCTAssertEqual(patch, ["waiting_room_level": "ORGANIZATION"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "OAuth synthetic-token")
    }

    func testUnknownFieldsRetainedWithoutPublicDefault() async throws {
        let raw = #"{"id":"123","join_url":"https://telemost.yandex.ru/j/123","waiting_room_level":"FUTURE_POLICY","future":42}"#
        let api = TelemostAPI(transport: TelemostScriptedHTTP([telemostJSON(raw)]))
        let value = try await api.conference(scope: scope, token: "test")
        XCTAssertEqual(value.waitingRoomRaw, "FUTURE_POLICY")
        XCTAssertNil(value.waitingRoom)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: value.retainedJSON) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? NSDictionary)
    }

    func testCrossScopeReturnedIDRejected() async throws {
        let bad = #"{"id":"456","join_url":"https://telemost.yandex.ru/j/456","waiting_room_level":"PUBLIC"}"#
        let api = TelemostAPI(transport: TelemostScriptedHTTP([telemostJSON(bad)]))
        do { _ = try await api.conference(scope: scope, token: "test"); XCTFail("cross-scope result accepted") }
        catch { XCTAssertEqual(error as? TelemostFailure, .invalidResponse) }
    }

    func testStreamingLimitAndRedirectRejection() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TelemostURLProtocol.self]
        let transport = TelemostURLSessionTransport(configuration: config)
        for (path, expected) in [("large", TelemostFailure.bodyTooLarge), ("redirect", .redirectRejected)] {
            var request = URLRequest(url: URL(string: "https://cloud-api.yandex.net/\(path)")!)
            request.setValue("OAuth synthetic", forHTTPHeaderField: "Authorization")
            do { _ = try await transport.response(to: request); XCTFail("unsafe response accepted") }
            catch { XCTAssertEqual(error as? TelemostFailure, expected) }
        }
        var wrong = URLRequest(url: URL(string: "https://evil.example/")!)
        wrong.setValue("OAuth synthetic", forHTTPHeaderField: "Authorization")
        do { _ = try await transport.response(to: wrong); XCTFail("credential origin accepted") }
        catch { XCTAssertEqual(error as? TelemostFailure, .invalidConfiguration) }
    }

    func testReadCooldownAndMutationNoRetry() async throws {
        let clock = TelemostTestClock()
        let http = TelemostScriptedHTTP([telemostJSON("{}", status: 429, headers: ["Retry-After": "2"]), telemostJSON(telemostConferenceFixture)])
        let api = TelemostAPI(transport: http, clock: clock)
        _ = try await api.conference(scope: scope, token: "test")
        let intervals = await clock.intervals
        XCTAssertEqual(intervals, [2])
        for status in [429, 503] {
            let failing = TelemostScriptedHTTP([telemostJSON("{}", status: status), telemostJSON(telemostConferenceFixture, status: 201)])
            do { _ = try await TelemostAPI(transport: failing).create(accountID: telemostTestAccountID, request: .init(waitingRoom: .admins), token: "test"); XCTFail("failure accepted") }
            catch {}
            let requests = await failing.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testCohostPageAndInvalidOffset() async throws {
        let http = TelemostScriptedHTTP([telemostJSON(#"{"cohosts":[{"email":"a@example.test"},{"email":"b@example.test"}]}"#)])
        let api = TelemostAPI(transport: http)
        let page = try await api.cohosts(scope: scope, offset: 0, limit: 2, token: "test")
        XCTAssertEqual(page.emails, ["a@example.test", "b@example.test"])
        XCTAssertFalse(page.complete)
        do { _ = try await api.cohosts(scope: scope, offset: -1, limit: 2, token: "test"); XCTFail("negative offset") } catch {}
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testOpaqueIDsCannotEscapePath() async throws {
        for id in ["..", "/", "a?b", "a#b", "a%2fb"] {
            let http = TelemostScriptedHTTP([telemostJSON(telemostConferenceFixture)])
            do { _ = try await TelemostAPI(transport: http).conference(scope: .init(accountID: telemostTestAccountID, conferenceID: id), token: "test"); XCTFail("unsafe ID") } catch {}
            let requests = await http.requests
            XCTAssertTrue(requests.isEmpty, id)
        }
    }
}
