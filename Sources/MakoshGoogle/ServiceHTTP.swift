import Foundation

/// What an HTTP exchange with a Google or WebDAV server came to, without the body, the URL or a token.
public enum ServiceHTTPError: Error, Equatable, Sendable {
    /// 429 or 503: pause this account for the given seconds.
    case retryAfter(TimeInterval)
    /// 412: the ETag moved; reread and reconcile in the next pass.
    case preconditionFailed
    /// A dropped connection, a timeout or a non-HTTP answer: the server may have applied the request.
    case transport(stage: String)
    /// 408, 409 or 5xx: the outcome is unknown.
    case unknownOutcome(stage: String)
    /// Any other 4xx.
    case rejected(code: Int, stage: String)
    case responseTooLarge
}

extension URLSession {
    /// No cache, no cookies, no stored credentials.
    public static var serviceEphemeral: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }
}

/// Refuses redirects to another host or to plain HTTP.
final class ServiceRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let same = request.url?.host?.lowercased() == task.originalRequest?.url?.host?.lowercased() && request.url?.scheme == "https"
        completionHandler(same ? request : nil)
    }
}

/// HTTP for Google and WebDAV servers. Failures carry the status code and a stage name only:
/// never the body, the URL or a token.
public struct ServiceHTTP: Sendable {
    let session: URLSession
    let timeout: TimeInterval

    public init(session: URLSession = .serviceEphemeral, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    /// Any status comes back; only transport failures throw. For OAuth, whose
    /// error codes live in the body.
    public func raw(_ request: URLRequest, stage: String, limit: Int = 64 << 10) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: ServiceRedirectGuard())
        } catch {
            throw ServiceHTTPError.transport(stage: stage)
        }
        guard let http = response as? HTTPURLResponse else { throw ServiceHTTPError.transport(stage: stage) }
        guard data.count <= limit else { throw ServiceHTTPError.responseTooLarge }
        return (data, http)
    }

    public func send(_ request: URLRequest, stage: String, limit: Int = 10 << 20) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: ServiceRedirectGuard())
        } catch {
            throw ServiceHTTPError.transport(stage: stage)
        }
        guard let http = response as? HTTPURLResponse else { throw ServiceHTTPError.transport(stage: stage) }
        guard data.count <= limit else { throw ServiceHTTPError.responseTooLarge }
        let status = http.statusCode
        switch status {
        case 200..<300, 304: return (data, http)
        case 412: throw ServiceHTTPError.preconditionFailed
        case 429, 503:
            if status == 503, http.value(forHTTPHeaderField: "Retry-After") == nil { throw ServiceHTTPError.unknownOutcome(stage: stage) }
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw ServiceHTTPError.retryAfter(min(max(seconds, 1), 3600))
        case 408, 409, 500...: throw ServiceHTTPError.unknownOutcome(stage: stage)
        default: throw ServiceHTTPError.rejected(code: status, stage: stage)
        }
    }
}
