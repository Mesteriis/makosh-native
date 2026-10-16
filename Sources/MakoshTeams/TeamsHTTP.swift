import Foundation

public struct TeamsHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }
    func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
}

public protocol TeamsHTTPTransport: Sendable {
    func response(to request: URLRequest) async throws -> TeamsHTTPResponse
    func upload(file: URL, to request: URLRequest) async throws -> TeamsHTTPResponse
}

public extension TeamsHTTPTransport {
    func upload(file: URL, to request: URLRequest) async throws -> TeamsHTTPResponse { throw TeamsFailure.invalidResource }
}

public protocol TeamsRetryClock: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct TeamsSystemRetryClock: TeamsRetryClock {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// Each request owns a delegate/session. No cookies, cached responses or credential storage.
public struct TeamsURLSessionTransport: TeamsHTTPTransport {
    private let configuration: URLSessionConfiguration
    public init() { self.init(configuration: .ephemeral) }
    init(configuration: URLSessionConfiguration) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.httpCookieStorage = nil; copy.urlCredentialStorage = nil; copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.timeoutIntervalForRequest = 30; copy.timeoutIntervalForResource = 30
        self.configuration = copy
    }
    public func response(to request: URLRequest) async throws -> TeamsHTTPResponse {
        try await exchange(request, file: nil)
    }
    public func upload(file: URL, to request: URLRequest) async throws -> TeamsHTTPResponse {
        guard file.isFileURL, request.httpMethod == "PUT", request.httpBody == nil,
              let url = request.url, TeamsGraphURL.accepts(url) else { throw TeamsFailure.invalidResource }
        return try await exchange(request, file: file)
    }
    private func exchange(_ request: URLRequest, file: URL?) async throws -> TeamsHTTPResponse {
        guard let url = request.url, url.scheme?.lowercased() == "https" else { throw TeamsFailure.invalidResource }
        if request.value(forHTTPHeaderField: "Authorization") != nil, !TeamsGraphURL.accepts(url) {
            throw TeamsFailure.invalidResource
        }
        let exchange = TeamsHTTPExchange(configuration: configuration)
        return try await withTaskCancellationHandler {
            try await exchange.run(request, file: file)
        } onCancel: { exchange.cancel() }
    }
}

private final class TeamsHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<TeamsHTTPResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var cancelled = false
    private let limit = 4 * 1024 * 1024

    init(configuration: URLSessionConfiguration) { self.configuration = configuration }

    func run(_ request: URLRequest, file: URL?) async throws -> TeamsHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task: URLSessionDataTask
            if let file { task = session.uploadTask(with: request, fromFile: file) }
            else { task = session.dataTask(with: request) }
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<TeamsHTTPResponse, any Error>) {
        let work = lock.withLock { () -> (CheckedContinuation<TeamsHTTPResponse, any Error>?, URLSession?) in
            let pending = continuation; continuation = nil
            let active = session; session = nil; task = nil
            return (pending, active)
        }
        work.1?.invalidateAndCancel()
        work.0?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(TeamsFailure.invalidResponse)); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(TeamsFailure.bodyTooLarge)); return
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accepted = lock.withLock { () -> Bool in
            guard continuation != nil, data.count <= limit - body.count else { return false }
            body.append(data); return true
        }
        if !accepted { finish(.failure(TeamsFailure.bodyTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(TeamsFailure.redirectRejected))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error is CancellationError ? CancellationError() : TeamsFailure.transport)); return }
        let result = lock.withLock { () -> TeamsHTTPResponse? in
            guard let response else { return nil }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String { result[key] = String(describing: pair.value) }
            }
            return TeamsHTTPResponse(status: response.statusCode, headers: headers, body: body)
        }
        if let result { finish(.success(result)) } else { finish(.failure(TeamsFailure.invalidResponse)) }
    }
}
