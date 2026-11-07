import Foundation

// Transferred from MacTower `JiraTransport.swift` (317eeaf): the request value,
// the retry-after parser and the request validation rules. OAuth 1.0a, custom
// CA and Data Center branches are not carried over.

/// Cloud credentials: an Atlassian site origin, the account email and an API token.
/// The token never appears in descriptions, mirrors or errors.
public struct JiraCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let origin: URL
    public let email: String
    public let apiToken: String
    public init(origin: URL, email: String, apiToken: String) {
        self.origin = origin
        self.email = email
        self.apiToken = apiToken
    }
    public var description: String { "JiraCredential(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    func validated() throws -> JiraCredential {
        guard origin.scheme?.lowercased() == "https", let host = origin.host, !host.isEmpty, origin.path.isEmpty || origin.path == "/",
            origin.query == nil, origin.user == nil
        else { throw JiraAdapterError.invalidRequest }
        guard Self.validSecret(email), !email.contains(":"), Self.validSecret(apiToken), !apiToken.contains(" ") else {
            throw JiraAdapterError.unauthorized
        }
        return self
    }
    static func validSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

public enum JiraRetryAfter: Equatable, Sendable {
    case seconds(Int)
    case date(Date)

    static func parse(_ value: String?) -> Self? {
        guard let value, value.utf8.count <= 128 else { return nil }
        if value.wholeMatch(of: /[0-9]+/) != nil, let seconds = Int(value), (0...Int(Int32.max)).contains(seconds) {
            return .seconds(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return nil }
        return .date(date)
    }

    /// Seconds from `now`, never negative.
    public func interval(from now: Date = Date()) -> TimeInterval {
        switch self {
        case .seconds(let value): return TimeInterval(value)
        case .date(let date): return max(0, date.timeIntervalSince(now))
        }
    }
}

public struct JiraRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }
    public let path: String
    public let method: Method
    public let query: [URLQueryItem]
    public let body: Data?
    public let expectsNoContent: Bool

    public init(path: String, method: Method = .get, query: [URLQueryItem] = [], body: Data? = nil, expectsNoContent: Bool = false) {
        self.path = path
        self.method = method
        self.query = query
        self.body = body
        self.expectsNoContent = expectsNoContent
    }

    public var description: String { "JiraRequest(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// True for a Cloud search continuation, the one request whose 400 body is inspected.
    var isCloudSearchContinuation: Bool {
        guard path == "/rest/api/3/search/jql", method == .post, let body,
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let token = object["nextPageToken"] as? String, !token.isEmpty, token.utf8.count <= 2048
        else { return false }
        return true
    }
}

struct JiraOrigin: Equatable, Sendable {
    let scheme: String?
    let host: String?
    let port: Int

    init(_ url: URL) {
        scheme = url.scheme?.lowercased()
        host = url.host?.lowercased()
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}
