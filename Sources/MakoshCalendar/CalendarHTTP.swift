import Foundation
import MakoshGoogle

/// Transport outcomes the calendar service handles itself rather than as plain failures.
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
    public static var calendarEphemeral: URLSession { .serviceEphemeral }
}

/// The shared `ServiceHTTP` with its outcomes expressed as calendar failures.
public struct CalendarHTTP: Sendable {
    public let service: ServiceHTTP

    public init(session: URLSession = .serviceEphemeral, timeout: TimeInterval = 30) {
        service = ServiceHTTP(session: session, timeout: timeout)
    }

    public init(service: ServiceHTTP) { self.service = service }

    /// Any status comes back; only transport failures throw.
    func raw(_ request: URLRequest, stage: String, limit: Int = 64 << 10) async throws -> (Data, HTTPURLResponse) {
        do { return try await service.raw(request, stage: stage, limit: limit) } catch let error as ServiceHTTPError {
            throw Self.failure(error)
        }
    }

    public func send(_ request: URLRequest, stage: String, limit: Int = 10 << 20) async throws -> (Data, HTTPURLResponse) {
        do { return try await service.send(request, stage: stage, limit: limit) } catch let error as ServiceHTTPError {
            throw Self.failure(error)
        }
    }

    static func failure(_ error: ServiceHTTPError) -> Error {
        switch error {
        case .retryAfter(let seconds): CalendarHTTPError.retryAfter(seconds)
        case .preconditionFailed: CalendarHTTPError.preconditionFailed
        case .transport(let stage), .unknownOutcome(let stage): CalendarFailure.unknownOutcome(stage: stage)
        case .rejected(let code, let stage): CalendarFailure.rejected(code: code, stage: stage)
        case .responseTooLarge: CalendarFailure.invalidInput("response too large")
        }
    }
}

extension GoogleOAuth {
    /// What the calendar asks Google for.
    public static let calendarScopes = GoogleOAuth.identityScopes + " https://www.googleapis.com/auth/calendar"
}

extension CalendarFailure {
    /// A Google sign-in or token failure as the calendar reports it.
    public init(google failure: GoogleOAuthFailure) {
        switch failure {
        case .notConfigured, .signInRequired: self = .signInRequired
        case .adminBlocked: self = .adminBlocked
        case .transport(let stage): self = .unknownOutcome(stage: stage)
        case .rejected(let code, let stage): self = .rejected(code: code, stage: stage)
        case .listenerUnavailable: self = .unreachable
        }
    }

    /// Rethrows Google failures as calendar failures; everything else passes through.
    static func mapGoogle<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let failure as GoogleOAuthFailure { throw CalendarFailure(google: failure) }
    }
}
