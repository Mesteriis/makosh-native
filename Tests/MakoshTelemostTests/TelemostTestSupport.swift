import Foundation
import MakoshTelemost

let telemostTestAccountID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!

actor TelemostScriptedHTTP: TelemostHTTPTransport {
    var responses: [TelemostHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [TelemostHTTPResponse]) { self.responses = responses }
    func response(to request: URLRequest) async throws -> TelemostHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.networkConnectionLost) }
        return responses.removeFirst()
    }
}

func telemostJSON(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> TelemostHTTPResponse {
    .init(status: status, headers: headers, body: Data(text.utf8))
}

let telemostConferenceFixture = #"{"id":"123","join_url":"https://telemost.yandex.ru/j/123","waiting_room_level":"ADMINS","is_auto_summarization_enabled":false,"future_field":{"retained":true}}"#

actor TelemostTestClock: TelemostRetryClock {
    private(set) var intervals: [TimeInterval] = []
    func sleep(seconds: TimeInterval) async throws { intervals.append(seconds) }
}

final class TelemostURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cloud-api.yandex.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path.hasSuffix("redirect") {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": "https://example.invalid/token-sink"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://example.invalid/token-sink")!), redirectResponse: response)
        } else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            for _ in 0..<5 { client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 1024 * 1024)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
