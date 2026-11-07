import Foundation

// Transferred from MacTower `JiraTransport.swift` (317eeaf): request bounds,
// Basic authorization, bounded sessions, failure mapping. The credential is
// held by value; OAuth 1.0a, custom CA and Data Center endpoints are removed.

public struct JiraTransport: Sendable, CustomReflectable {
    public static let maximumRequestBytes = 64 * 1024
    public static let maximumResponseBytes = 8 * 1024 * 1024
    private let credential: JiraCredential
    private let configurationFactory: @Sendable () -> URLSessionConfiguration

    public init(credential: JiraCredential, sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.credential = credential
        configurationFactory = sessionConfiguration
    }

    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public var origin: URL { credential.origin }

    public func send(_ request: JiraRequest) async throws -> Data {
        let credential = try credential.validated()
        guard (request.body?.count ?? 0) <= Self.maximumRequestBytes else { throw JiraAdapterError.invalidRequest }
        guard request.path.wholeMatch(of: /\/[A-Za-z0-9_\/.-]+/) != nil, !request.path.contains("//"), request.path.utf8.count <= 1024,
            request.query.count <= 20, request.query.allSatisfy({ $0.name.utf8.count <= 128 && ($0.value?.utf8.count ?? 0) <= 4096 })
        else { throw JiraAdapterError.invalidRequest }
        var components = URLComponents(url: credential.origin, resolvingAgainstBaseURL: false)!
        components.path = request.path
        components.queryItems = request.query.isEmpty ? nil : request.query
        guard let url = components.url, url.absoluteString.utf8.count <= 8192 else { throw JiraAdapterError.invalidRequest }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil { urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        urlRequest.setValue(Self.authorization(credential), forHTTPHeaderField: "Authorization")
        let configuration = configurationFactory()
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let operation = JiraSessionRequest(
            origin: credential.origin, responseType: request.expectsNoContent ? .noContent : .json,
            maximumResponseBytes: Self.maximumResponseBytes, inspectInvalidCursor: request.isCloudSearchContinuation
        ) { _ in Self.authorization(credential) }
        do {
            return try await operation.run(urlRequest, configuration: configuration)
        } catch let failure as JiraTransportFailure {
            throw Self.map(failure)
        }
    }

    private static func authorization(_ credential: JiraCredential) -> String {
        "Basic " + Data("\(credential.email):\(credential.apiToken)".utf8).base64EncodedString()
    }

    static func map(_ failure: JiraTransportFailure) -> JiraAdapterError {
        switch failure {
        case .httpStatus(let status, let retryAfter):
            switch status {
            case 401, 403: return .unauthorized
            case 404: return .notFound
            case 429, 503: return .rateLimited(retryAfter: retryAfter?.interval())
            default: return .http(status: status)
            }
        case .invalidContinuation: return .invalidCursor
        case .invalidRequest, .requestTooLarge: return .invalidRequest
        case .responseTooLarge, .nonHTTPResponse, .invalidContentType: return .invalidResponse
        case .redirectRejected: return .transport(code: "redirectRejected")
        case .tlsFailure: return .transport(code: "tlsFailure")
        case .timedOut: return .transport(code: "timedOut")
        case .cancelled: return .transport(code: "cancelled")
        case .networkFailure: return .transport(code: "networkFailure")
        }
    }
}
