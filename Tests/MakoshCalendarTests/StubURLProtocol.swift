import Foundation
@testable import MakoshCalendar

/// Answers requests from a test-provided handler; records what was asked.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        var redirect: URL?
        var error: URLError?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func install(_ handler: @escaping (URLRequest) -> Reply) {
        lock.withLock {
            Self.handler = handler
            recorded = []
        }
    }
    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    static func http() -> CalendarHTTP { CalendarHTTP(session: session(), timeout: 5) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.recorded.append(request)
            return Self.handler?(request) ?? Reply(status: 500)
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let redirect = reply.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
