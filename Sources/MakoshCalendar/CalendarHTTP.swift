import Foundation

/// Transport outcomes the service handles itself rather than as plain failures.
public enum CalendarHTTPError: Error, Equatable, Sendable {
    /// 429 or 503: pause this account for the given seconds.
    case retryAfter(TimeInterval)
    /// 412: the ETag moved; reread and reconcile in the next pass.
    case preconditionFailed

    public var failure: CalendarFailure {
        switch self {
        case .retryAfter: .unreachable
        case .preconditionFailed: .unknownOutcome(stage: "precondition")
        }
    }
}

extension URLSession {
    /// No cache, no cookies, no stored credentials.
    public static var calendarEphemeral: URLSession {
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
final class CalendarRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let same = request.url?.host?.lowercased() == task.originalRequest?.url?.host?.lowercased() && request.url?.scheme == "https"
        completionHandler(same ? request : nil)
    }
}

/// HTTP for calendar servers. Failures carry the status code and a stage name only:
/// never the body, the URL or a token.
public struct CalendarHTTP: Sendable {
    let session: URLSession
    let timeout: TimeInterval

    public init(session: URLSession = .calendarEphemeral, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    public func send(_ request: URLRequest, stage: String, limit: Int = 10 << 20) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: CalendarRedirectGuard())
        } catch {
            throw CalendarFailure.unknownOutcome(stage: stage)
        }
        guard let http = response as? HTTPURLResponse else { throw CalendarFailure.unknownOutcome(stage: stage) }
        guard data.count <= limit else { throw CalendarFailure.invalidInput("response too large") }
        let status = http.statusCode
        switch status {
        case 200..<300, 304: return (data, http)
        case 412: throw CalendarHTTPError.preconditionFailed
        case 429, 503:
            if status == 503, http.value(forHTTPHeaderField: "Retry-After") == nil { throw CalendarFailure.unknownOutcome(stage: stage) }
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw CalendarHTTPError.retryAfter(min(max(seconds, 1), 3600))
        case 408, 409, 500...: throw CalendarFailure.unknownOutcome(stage: stage)
        default: throw CalendarFailure.rejected(code: status, stage: stage)
        }
    }
}
