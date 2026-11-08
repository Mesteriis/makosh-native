import Foundation
import MakoshGoogle

/// The shared `ServiceHTTP` with its outcomes expressed as section failures.
public struct PersonsHTTP: Sendable {
    public let service: ServiceHTTP

    public init(session: URLSession = .serviceEphemeral, timeout: TimeInterval = 30) {
        service = ServiceHTTP(session: session, timeout: timeout)
    }

    public init(service: ServiceHTTP) { self.service = service }

    public func send(_ request: URLRequest, stage: String, limit: Int = 10 << 20) async throws -> (Data, HTTPURLResponse) {
        do { return try await service.send(request, stage: stage, limit: limit) } catch let error as ServiceHTTPError {
            throw Self.failure(error)
        }
    }

    static func failure(_ error: ServiceHTTPError) -> PersonsFailure {
        switch error {
        case .retryAfter(let seconds): .retryAfter(Int(seconds))
        case .preconditionFailed: .preconditionFailed
        case .transport(let stage), .unknownOutcome(let stage): .unknownOutcome(stage: stage)
        case .rejected(let code, let stage): .rejected(code: code, stage: stage)
        case .responseTooLarge: .invalidInput("response too large")
        }
    }
}

extension PersonsFailure {
    /// A Google sign-in or token failure as the section reports it.
    public init(google failure: GoogleOAuthFailure) {
        switch failure {
        case .notConfigured, .signInRequired, .adminBlocked: self = .signInRequired
        case .transport(let stage): self = .unknownOutcome(stage: stage)
        case .rejected(let code, let stage): self = .rejected(code: code, stage: stage)
        case .listenerUnavailable: self = .unreachable
        }
    }

    static func mapGoogle<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let failure as GoogleOAuthFailure { throw PersonsFailure(google: failure) }
    }
}

extension GoogleOAuth {
    /// What the Persons section asks Google for.
    public static let contactsScopes = GoogleOAuth.identityScopes + " https://www.googleapis.com/auth/contacts"
    public static let contactsScope = "https://www.googleapis.com/auth/contacts"
}
