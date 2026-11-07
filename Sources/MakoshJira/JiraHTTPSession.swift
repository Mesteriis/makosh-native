import Foundation
import Security

// Transferred from MacTower `JiraHTTPSession.swift` (317eeaf). Custom CA
// anchors and the OAuth form response type are removed; everything else —
// one ephemeral session per call, origin-pinned redirects for GET only,
// bounded buffering, sanitized errors and the 16 KiB window for the Cloud
// search-continuation error — is kept.

/// SSL policy always validates the configured host; nothing touches the keychain or process-wide trust.
struct JiraTLSConfiguration: Sendable {
    let origin: JiraOrigin

    func evaluate(_ trust: SecTrust, host: String, port: Int) -> Bool {
        guard origin.scheme == "https", host.lowercased() == origin.host, port == origin.port, let expectedHost = origin.host,
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, expectedHost as CFString)) == errSecSuccess
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

enum JiraTransportFailure: Error, Equatable, Sendable {
    case invalidRequest, requestTooLarge, responseTooLarge, nonHTTPResponse, invalidContentType
    case redirectRejected, tlsFailure, timedOut, cancelled, networkFailure
    case invalidContinuation
    case httpStatus(Int, retryAfter: JiraRetryAfter?)
}

/// All mutable state is protected by a lock; callbacks use a serial queue.
final class JiraSessionRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum ResponseType { case json, noContent }
    private let origin: JiraOrigin
    private let tls: JiraTLSConfiguration
    private let responseType: ResponseType
    private let maximumResponseBytes: Int
    private let inspectInvalidCursor: Bool
    private let redirectAuthorization: @Sendable (URLRequest) throws -> String
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var completed = false
    private var cancelled = false
    private var data = Data()
    private var redirectCount = 0
    private var errorResponse: JiraTransportFailure?

    init(
        origin: URL, responseType: ResponseType = .json, maximumResponseBytes: Int, inspectInvalidCursor: Bool = false,
        redirectAuthorization: @escaping @Sendable (URLRequest) throws -> String
    ) {
        self.origin = JiraOrigin(origin)
        tls = JiraTLSConfiguration(origin: JiraOrigin(origin))
        self.responseType = responseType
        self.maximumResponseBytes = maximumResponseBytes
        self.inspectInvalidCursor = inspectInvalidCursor
        self.redirectAuthorization = redirectAuthorization
    }

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: JiraTransportFailure.cancelled)
                    return
                }
                self.continuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            self.finish(.failure(JiraTransportFailure.cancelled))
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        data.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(JiraTransportFailure.nonHTTPResponse))
            return
        }
        guard let url = http.url, JiraOrigin(url) == origin, url.user == nil, url.password == nil else {
            completionHandler(.cancel)
            finish(.failure(JiraTransportFailure.redirectRejected))
            return
        }
        let mime =
            (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let isJSON = mime == "application/json" || (mime.hasPrefix("application/") && mime.hasSuffix("+json"))
        guard (200..<300).contains(http.statusCode) else {
            let status = JiraTransportFailure.httpStatus(
                http.statusCode, retryAfter: JiraRetryAfter.parse(http.value(forHTTPHeaderField: "Retry-After")))
            // Only an actual Cloud search continuation gets this 16 KiB classification
            // window. All other error bodies are discarded at the response header.
            if inspectInvalidCursor, http.statusCode == 400, isJSON, response.expectedContentLength <= 16_384 {
                lock.withLock { errorResponse = status }
                completionHandler(.allow)
                return
            }
            completionHandler(.cancel)
            finish(.failure(status))
            return
        }
        let validType: Bool
        switch responseType {
        case .json: validType = isJSON
        case .noContent: validType = http.statusCode == 204
        }
        guard validType else {
            completionHandler(.cancel)
            finish(.failure(JiraTransportFailure.invalidContentType))
            return
        }
        guard response.expectedContentLength <= maximumResponseBytes else {
            completionHandler(.cancel)
            finish(.failure(JiraTransportFailure.responseTooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        let limit = errorResponse == nil ? maximumResponseBytes : 16_384
        guard chunk.count <= limit - data.count else {
            let failure = errorResponse ?? .responseTooLarge
            lock.unlock()
            finish(.failure(failure))
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let code = (error as? URLError)?.code
            let sanitized: JiraTransportFailure
            switch code {
            case .timedOut: sanitized = .timedOut
            case .cancelled: sanitized = .cancelled
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                .secureConnectionFailed, .clientCertificateRejected:
                sanitized = .tlsFailure
            default: sanitized = .networkFailure
            }
            finish(.failure(sanitized))
        } else {
            let (response, status) = lock.withLock { (data, errorResponse) }
            if let status {
                let parsed = try? JSONDecoder().decode(SearchCursorError.self, from: response)
                let expired =
                    parsed?.errorMessages == ["The provided next page token is invalid or expired."] && parsed?.errors?.isEmpty != false
                finish(.failure(expired ? JiraTransportFailure.invalidContinuation : status))
            } else {
                finish(.success(response))
            }
        }
    }

    private struct SearchCursorError: Decodable {
        let errorMessages: [String]
        let errors: [String: String]?
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = lock.withLock { () -> Bool in
            redirectCount += 1
            return redirectCount <= 5
        }
        guard allowed, let url = request.url, JiraOrigin(url) == origin, url.user == nil, url.password == nil, url.fragment == nil,
            url.absoluteString.utf8.count <= 8192,
            // Never replay or transform a mutating request through a redirect.
            task.originalRequest?.httpMethod == "GET", request.httpMethod == "GET"
        else {
            completionHandler(nil)
            finish(.failure(JiraTransportFailure.redirectRejected))
            return
        }
        var redirected = request
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        do {
            redirected.setValue(try redirectAuthorization(redirected), forHTTPHeaderField: "Authorization")
            completionHandler(redirected)
        } catch {
            completionHandler(nil)
            finish(.failure(JiraTransportFailure.redirectRejected))
        }
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(JiraTransportFailure.networkFailure))
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
            tls.evaluate(trust, host: challenge.protectionSpace.host, port: challenge.protectionSpace.port)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(JiraTransportFailure.tlsFailure))
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
