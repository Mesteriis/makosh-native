import Foundation
import OSLog

// Transferred from MacTower `JiraDiagnostics.swift` (317eeaf), re-targeted.
/// Only local enum cases and HTTP status codes may enter unified logging.
/// Never log error descriptions from Foundation, response bodies, requests or identities.
public enum JiraDiagnostics {
    private static let logger = Logger(subsystem: "org.makosh", category: "jira")

    public static func recordFailure(_ error: any Error, stage: StaticString) {
        logger.error("Jira stage=\(String(describing: stage), privacy: .public) error=\(code(error), privacy: .public)")
    }

    public static func code(_ error: any Error) -> String {
        switch error {
        case JiraAdapterError.http(let status): return "http.\(status)"
        case JiraAdapterError.rateLimited: return "http.rateLimited"
        case JiraAdapterError.transport(let code): return "transport.\(code)"
        case JiraAdapterError.unsupportedFields: return "adapter.unsupportedFields"
        case let value as JiraAdapterError: return "adapter.\(value)"
        case is CancellationError: return "cancelled"
        case is DecodingError: return "adapter.invalidResponse"
        default: return "local.failure"
        }
    }
}
