import Foundation
import XCTest

@testable import MakoshOSINT

final class FlowsintClientTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:51234")!

    private func client(credentials: (email: String, password: String)? = ("makosh-osint@sh-inc.dev", "pw-1")) -> FlowsintClient {
        FlowsintClient(baseURL: base, http: StubURLProtocol.http(), credentials: { credentials })
    }

    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testLoginSendsFormAndStoresBearer() async throws {
        StubURLProtocol.install { request in
            switch request.url!.path {
            case "/api/auth/token": return .init(body: self.json(["access_token": "tok-1", "token_type": "bearer"]))
            case "/api/keys":
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1" else { return .init(status: 401) }
                return .init(body: self.json([["id": "k1", "name": "HIBP_API_KEY"]]))
            default: return .init(status: 404)
            }
        }
        let keys = try await client().keys()
        XCTAssertEqual(keys, [FlowsintKey(id: "k1", name: "HIBP_API_KEY")])
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.map(\.url!.path), ["/api/auth/token", "/api/keys"])
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let form = String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(form.contains("username=makosh-osint%40sh-inc.dev"), form)
        XCTAssertTrue(form.contains("password=pw-1"), form)
    }

    func testExpiredTokenReloginsOnce() async throws {
        final class Counter: @unchecked Sendable {
            var tokens = 0
            var keys = 0
        }
        let counter = Counter()
        StubURLProtocol.install { request in
            switch request.url!.path {
            case "/api/auth/token":
                counter.tokens += 1
                return .init(body: self.json(["access_token": "tok-\(counter.tokens)", "token_type": "bearer"]))
            case "/api/keys":
                counter.keys += 1
                // The first token is stale: only the second one is accepted.
                return request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-2"
                    ? .init(body: self.json([])) : .init(status: 401)
            default: return .init(status: 404)
            }
        }
        let keys = try await client().keys()
        XCTAssertEqual(keys, [])
        XCTAssertEqual(counter.tokens, 2)
        XCTAssertEqual(counter.keys, 2)

        StubURLProtocol.install { request in
            request.url!.path == "/api/auth/token"
                ? .init(body: self.json(["access_token": "t", "token_type": "bearer"])) : .init(status: 401)
        }
        do {
            _ = try await client().keys()
            XCTFail("a second 401 is an authentication failure")
        } catch { XCTAssertEqual(error as? OSINTFailure, .serviceAuthFailed, "\(error)") }
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.url!.path == "/api/auth/token" }.count, 2, "exactly one re-login")
    }

    func testAddNodeBodyUsesPrimaryField() async throws {
        StubURLProtocol.install { request in
            switch request.url!.path {
            case "/api/auth/token": return .init(body: self.json(["access_token": "t", "token_type": "bearer"]))
            case "/api/sketches/sk-1/nodes/add": return .init(body: self.json(["status": "node added", "id": "4:abc:17"]))
            default: return .init(status: 404)
            }
        }
        let id = try await client().addNode(sketchID: "sk-1", type: .email, value: "anna@example.test")
        XCTAssertEqual(id, "4:abc:17")
        let request = StubURLProtocol.requests.last!
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let node = body(request)
        XCTAssertEqual(node["nodeType"] as? String, "Email")
        XCTAssertEqual(node["nodeLabel"] as? String, "anna@example.test")
        XCTAssertEqual((node["nodeProperties"] as? [String: Any])?["email"] as? String, "anna@example.test")
        XCTAssertNotNil(node["nodeMetadata"])
    }

    func testLaunchReturnsTaskIDAndScanMapsStatuses() async throws {
        StubURLProtocol.install { request in
            switch request.url!.path {
            case "/api/auth/token": return .init(body: self.json(["access_token": "t", "token_type": "bearer"]))
            case "/api/enrichers/email_to_gravatar/launch": return .init(body: self.json(["id": "task-9"]))
            case "/api/scans/task-9": return .init(body: self.json(["id": "task-9", "sketch_id": "sk-1", "status": "COMPLETED"]))
            case "/api/scans/task-10": return .init(body: self.json(["id": "task-10", "sketch_id": "sk-1", "status": "RUNNING"]))
            default: return .init(status: 404)
            }
        }
        let api = client()
        let task = try await api.launch(enricher: .emailToGravatar, sketchID: "sk-1", nodeIDs: ["4:abc:17"])
        XCTAssertEqual(task, "task-9")
        let launch = body(StubURLProtocol.requests.last!)
        XCTAssertEqual(launch["sketch_id"] as? String, "sk-1")
        XCTAssertEqual(launch["node_ids"] as? [String], ["4:abc:17"])
        let done = try await api.scan(id: "task-9")
        XCTAssertEqual(done, .completed)
        let running = try await api.scan(id: "task-10")
        XCTAssertEqual(running, .running)
    }

    func testSketchLifecycleAndGraphDecoding() async throws {
        StubURLProtocol.install { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("POST", "/api/auth/token"): return .init(body: self.json(["access_token": "t", "token_type": "bearer"]))
            case ("GET", "/api/sketches/missing"): return .init(status: 404, body: self.json(["detail": "Sketch not found"]))
            case ("GET", "/api/sketches/sk-1"):
                return .init(body: self.json(["id": "sk-1", "title": "T", "description": "Makosh", "investigation_id": "inv-1"]))
            case ("POST", "/api/sketches/create"):
                return .init(
                    status: 201, body: self.json(["id": "sk-2", "title": "P", "description": "Makosh", "investigation_id": "inv-1"]))
            case ("DELETE", "/api/sketches/sk-1"): return .init(status: 204)
            case ("GET", "/api/sketches/sk-1/graph"):
                return .init(
                    body: self.json([
                        "nodes": [
                            [
                                "id": "n1", "nodeType": "Email", "nodeLabel": "anna@example.test",
                                "nodeProperties": ["email": "anna@example.test"],
                            ],
                            [
                                "id": "n2", "nodeType": "Gravatar", "nodeLabel": "g",
                                "nodeProperties": ["hash": "h", "src": "https://www.gravatar.com/avatar/h", "exists": true],
                                "nodeMetadata": ["enricher": "email_to_gravatar"],
                            ],
                        ],
                        "edges": [["id": "e1", "source": "n1", "target": "n2", "label": "HAS_GRAVATAR"]],
                    ]))
            case ("POST", "/api/investigations/create"): return .init(status: 201, body: self.json(["id": "inv-1", "name": "Makosh"]))
            case ("GET", "/api/investigations"): return .init(body: self.json([["id": "inv-1", "name": "Makosh"]]))
            case ("GET", "/api/investigations/inv-1/sketches"):
                return .init(body: self.json([["id": "sk-1", "title": "T", "description": "", "investigation_id": "inv-1"]]))
            default: return .init(status: 404)
            }
        }
        let api = client()
        let missing = try await api.sketch(id: "missing")
        XCTAssertNil(missing)
        let found = try await api.sketch(id: "sk-1")
        XCTAssertEqual(found, FlowsintSketch(id: "sk-1", title: "T", investigationID: "inv-1"))
        let created = try await api.createSketch(title: "P", investigationID: "inv-1")
        XCTAssertEqual(created.id, "sk-2")
        XCTAssertEqual(body(StubURLProtocol.requests.last!)["investigation_id"] as? String, "inv-1")
        try await api.deleteSketch(id: "sk-1")
        let graph = try await api.graph(sketchID: "sk-1")
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(graph.nodes[1].type, "Gravatar")
        XCTAssertEqual(graph.nodes[1].properties["src"]?.stringValue, "https://www.gravatar.com/avatar/h")
        XCTAssertEqual(graph.nodes[1].properties["exists"], .bool(true))
        XCTAssertEqual(graph.nodes[1].metadata["enricher"]?.stringValue, "email_to_gravatar")
        XCTAssertEqual(graph.edges, [FlowsintEdge(source: "n1", target: "n2", label: "HAS_GRAVATAR")])
        let investigation = try await api.createInvestigation(name: "Makosh")
        XCTAssertEqual(investigation, FlowsintInvestigation(id: "inv-1", name: "Makosh"))
        let investigations = try await api.investigations()
        XCTAssertEqual(investigations, [investigation])
        let sketches = try await api.sketches(investigationID: "inv-1")
        XCTAssertEqual(sketches.map(\.id), ["sk-1"])
    }

    func testRegisterConflictIsFalse() async throws {
        StubURLProtocol.install { request in
            guard request.url!.path == "/api/auth/register" else { return .init(status: 404) }
            let email = self.body(request)["email"] as? String
            return email == "new@sh-inc.dev"
                ? .init(status: 201, body: self.json(["access_token": "t"]))
                : .init(status: 400, body: self.json(["detail": "Email already registered"]))
        }
        let created = try await client().register(email: "new@sh-inc.dev", password: "p")
        XCTAssertTrue(created)
        let existing = try await client().register(email: "makosh-osint@sh-inc.dev", password: "p")
        XCTAssertFalse(existing)
        XCTAssertNil(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "registration carries no token")
    }

    func testServerErrorsAreUnknownOutcomeWithStage() async throws {
        StubURLProtocol.install { request in
            request.url!.path == "/api/auth/token"
                ? .init(body: self.json(["access_token": "t", "token_type": "bearer"])) : .init(status: 503)
        }
        do {
            _ = try await client().launch(enricher: .phoneToInfos, sketchID: "sk", nodeIDs: ["n"])
            XCTFail("503 is an unknown outcome")
        } catch { XCTAssertEqual(error as? OSINTFailure, .unknownOutcome(stage: "launch"), "\(error)") }
        StubURLProtocol.install { request in
            request.url!.path == "/api/auth/token"
                ? .init(body: self.json(["access_token": "t", "token_type": "bearer"])) : .init(error: URLError(.networkConnectionLost))
        }
        do {
            _ = try await client().deleteSketch(id: "sk")
            XCTFail("a dropped connection is an unknown outcome")
        } catch { XCTAssertEqual(error as? OSINTFailure, .unknownOutcome(stage: "deleteSketch"), "\(error)") }
    }

    func testClientErrorsAreRejectedWithoutBody() async throws {
        StubURLProtocol.install { request in
            request.url!.path == "/api/auth/token"
                ? .init(body: self.json(["access_token": "t", "token_type": "bearer"]))
                : .init(status: 422, body: self.json(["detail": "secret-detail-text"]))
        }
        do {
            _ = try await client().launch(enricher: .phoneToInfos, sketchID: "sk", nodeIDs: ["n"])
            XCTFail("422 is a rejection")
        } catch {
            XCTAssertEqual(error as? OSINTFailure, .apiRejected(code: 422, stage: "launch"), "\(error)")
            XCTAssertFalse(String(reflecting: error).contains("secret-detail-text"))
        }
    }

    func testGraphOver10MBIsTooLargeAndBadJSONIsInvalid() async throws {
        StubURLProtocol.install { request in
            switch request.url!.path {
            case "/api/auth/token": return .init(body: self.json(["access_token": "t", "token_type": "bearer"]))
            case "/api/sketches/big/graph": return .init(body: Data(repeating: 0x20, count: 10 << 20 + 1))
            case "/api/sketches/bad/graph": return .init(body: Data("not json".utf8))
            default: return .init(status: 404)
            }
        }
        do {
            _ = try await client().graph(sketchID: "big")
            XCTFail("over the limit")
        } catch { XCTAssertEqual(error as? OSINTFailure, .tooLarge, "\(error)") }
        do {
            _ = try await client().graph(sketchID: "bad")
            XCTFail("not JSON")
        } catch { XCTAssertEqual(error as? OSINTFailure, .invalidResponse(stage: "graph"), "\(error)") }
    }

    func testMissingCredentialsIsServiceAuthFailed() async throws {
        StubURLProtocol.install { _ in .init(status: 500) }
        do {
            _ = try await client(credentials: nil).keys()
            XCTFail("no credentials, no request")
        } catch { XCTAssertEqual(error as? OSINTFailure, .serviceAuthFailed, "\(error)") }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testHealthNeedsNginxAndAPIBehindIt() async throws {
        // nginx answers /health itself with plain text; only a reply from /api/… proves the API behind it.
        StubURLProtocol.install { request in
            switch request.url!.path {
            case "/health": return .init(body: Data("healthy\n".utf8))
            case "/api/types": return .init(status: 401)
            default: return .init(status: 404)
            }
        }
        let up = try await client().health()
        XCTAssertTrue(up)
        XCTAssertEqual(StubURLProtocol.requests.map(\.url!.path), ["/health", "/api/types"])
        StubURLProtocol.install { request in
            request.url!.path == "/health" ? .init(body: Data("healthy\n".utf8)) : .init(status: 502)
        }
        let apiDown = try await client().health()
        XCTAssertFalse(apiDown, "502 from nginx means the API is not up")
        StubURLProtocol.install { _ in .init(error: URLError(.cannotConnectToHost)) }
        let nginxDown = (try? await client().health()) ?? false
        XCTAssertFalse(nginxDown)
    }
}
