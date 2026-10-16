import Foundation
import MakoshTeams

let teamsTestContext = TeamsAccountContext(
    accountID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
    principal: TeamsPrincipal(tenantID: "11111111-1111-4111-8111-111111111111",
                              userID: "22222222-2222-4222-8222-222222222222", displayName: "Test User"))

actor TeamsScriptedHTTP: TeamsHTTPTransport {
    var responses: [TeamsHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [TeamsHTTPResponse]) { self.responses = responses }
    func response(to request: URLRequest) async throws -> TeamsHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        return responses.removeFirst()
    }
}

func teamsJSON(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> TeamsHTTPResponse {
    TeamsHTTPResponse(status: status, headers: headers, body: Data(text.utf8))
}

actor TeamsTestDelay: TeamsRetryClock {
    private(set) var intervals: [TimeInterval] = []
    func sleep(seconds: TimeInterval) async throws { intervals.append(seconds) }
}

final class TeamsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "graph.microsoft.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path.hasSuffix("redirect") {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": "https://example.invalid/token-sink"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://example.invalid/token-sink")!), redirectResponse: response)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for _ in 0..<5 { client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 1024 * 1024)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

actor TeamsPausedHTTP: TeamsHTTPTransport {
    private var pending: CheckedContinuation<TeamsHTTPResponse, any Error>?
    private var requested = false
    private var observer: CheckedContinuation<Void, Never>?
    func response(to request: URLRequest) async throws -> TeamsHTTPResponse {
        requested = true; observer?.resume(); observer = nil
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { observer = $0 }
    }
    func complete(_ response: TeamsHTTPResponse) { pending?.resume(returning: response); pending = nil }
}
