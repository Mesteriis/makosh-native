import Foundation
@testable import MakoshJira

/// Answers requests from a queue; every request and body is kept for assertions.
final class JiraStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = ["Content-Type": "application/json"]
        var fail: URLError.Code? = nil
        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"].merging(headers) { _, new in new })
        }
        static func noContent() -> Reply { Reply(status: 204, body: Data(), headers: [:]) }
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
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JiraStubProtocol.self]
        return configuration
    }
    static func body(at index: Int) -> [String: Any]? {
        lock.withLock { bodies.indices.contains(index) ? try? JSONSerialization.jsonObject(with: bodies[index]) as? [String: Any] : nil }
    }
    static var recorded: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: Reply? = Self.lock.withLock {
            Self.requests.append(request)
            var data = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let count = stream.read(buffer, maxLength: 65536)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                stream.close()
            } else if let body = request.httpBody {
                data = body
            }
            Self.bodies.append(data)
            return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let code = reply.fail {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum JiraTestSupport {
    static let credential = JiraCredential(origin: URL(string: "https://jira.test")!, email: "me@example.com", apiToken: "secret-token")
    static func adapter() -> JiraCloudAdapter {
        JiraCloudAdapter(credential: credential, sessionConfiguration: { JiraStubProtocol.configuration })
    }
    static func transport() -> JiraTransport {
        JiraTransport(credential: credential, sessionConfiguration: { JiraStubProtocol.configuration })
    }
}
