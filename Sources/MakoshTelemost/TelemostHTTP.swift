import Foundation

public struct TelemostHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String], body: Data) { self.status = status; self.headers = headers; self.body = body }
}
public protocol TelemostHTTPTransport: Sendable {
    func response(to request: URLRequest) async throws -> TelemostHTTPResponse
}
public protocol TelemostRetryClock: Sendable { func sleep(seconds: TimeInterval) async throws }
public struct TelemostSystemRetryClock: TelemostRetryClock {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}
public struct TelemostURLSessionTransport: TelemostHTTPTransport {
    private let configuration: URLSessionConfiguration
    public init() { self.init(configuration: .ephemeral) }
    init(configuration: URLSessionConfiguration) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.httpCookieStorage = nil; copy.urlCredentialStorage = nil; copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.timeoutIntervalForRequest = 30; copy.timeoutIntervalForResource = 30
        self.configuration = copy
    }
    public func response(to request: URLRequest) async throws -> TelemostHTTPResponse {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.scheme == "https", ["cloud-api.yandex.net", "oauth.yandex.ru", "login.yandex.ru"].contains(url.host ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.fragment == nil, !(parts.queryItems ?? []).contains(where: { ["oauth_token", "access_token", "client_secret"].contains($0.name) }) else {
            throw TelemostFailure.invalidConfiguration
        }
        let exchange = TelemostHTTPExchange(configuration: configuration)
        return try await withTaskCancellationHandler { try await exchange.run(request) } onCancel: { exchange.cancel() }
    }
}

/// Each response owns a bounded delegate/session. Native callbacks are not MainActor-isolated.
private final class TelemostHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<TelemostHTTPResponse, any Error>?
    private var session: URLSession?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var cancelled = false
    private let limit = 4 * 1024 * 1024
    init(configuration: URLSessionConfiguration) { self.configuration = configuration }
    func run(_ request: URLRequest) async throws -> TelemostHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            lock.unlock(); task.resume()
        }
    }
    func cancel() { lock.withLock { cancelled = true }; finish(.failure(CancellationError())) }
    private func finish(_ result: Result<TelemostHTTPResponse, any Error>) {
        let work = lock.withLock { () -> (CheckedContinuation<TelemostHTTPResponse, any Error>?, URLSession?) in
            let pending = continuation; continuation = nil
            let active = session; session = nil
            return (pending, active)
        }
        work.1?.invalidateAndCancel(); work.0?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(TelemostFailure.invalidResponse)); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(TelemostFailure.bodyTooLarge)); return
        }
        lock.withLock { self.response = http }; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accepted = lock.withLock { () -> Bool in
            guard continuation != nil, data.count <= limit - body.count else { return false }
            body.append(data); return true
        }
        if !accepted { finish(.failure(TelemostFailure.bodyTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(TelemostFailure.redirectRejected))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error is CancellationError ? CancellationError() : TelemostFailure.transport)); return }
        let result = lock.withLock { () -> TelemostHTTPResponse? in
            guard let response else { return nil }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String { result[key] = String(describing: pair.value) }
            }
            return TelemostHTTPResponse(status: response.statusCode, headers: headers, body: body)
        }
        if let result { finish(.success(result)) } else { finish(.failure(TelemostFailure.invalidResponse)) }
    }
}
