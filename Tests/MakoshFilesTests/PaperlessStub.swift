import Foundation

/// Answers requests from a queue; every request and body is kept for assertions.
final class PaperlessStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = ["Content-Type": "application/json"]
        var fail = false
        var redirect: URL? = nil
        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"].merging(headers) { _, new in new })
        }
    }
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    private static let lock = NSLock()

    static func reset(_ replies: [Reply]) {
        lock.withLock {
            Self.replies = replies
            requests = []
            bodies = []
        }
    }
    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaperlessStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: Reply = Self.lock.withLock {
            Self.requests.append(request)
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                stream.close()
                Self.bodies.append(data)
            } else {
                Self.bodies.append(request.httpBody ?? Data())
            }
            return Self.replies.isEmpty ? Reply(status: 599) : Self.replies.removeFirst()
        }
        if let target = reply.redirect {
            var next = request
            next.url = target
            let redirect = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if reply.fail {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
