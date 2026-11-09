import Foundation

/// Every failure of the OSINT module: codes and stages only, never response bodies,
/// URLs with parameters, addresses, phones or secrets.
public enum OSINTFailure: Error, Codable, Equatable, Sendable {
    case disabled
    case notInstalled
    case sshUnreachable
    case sshAuthFailed
    case hostKeyMismatch
    case dockerMissing
    case gitMissing
    case installFailed(stage: String)
    case healthTimeout
    case serviceAuthFailed
    case apiRejected(code: Int, stage: String)
    case unknownOutcome(stage: String)
    case invalidResponse(stage: String)
    case tooLarge
    case storage(String?)
    case invalidInput(String)

    /// The case name, for the interface and the journal.
    public var code: String {
        switch self {
        case .disabled: "disabled"
        case .notInstalled: "notInstalled"
        case .sshUnreachable: "sshUnreachable"
        case .sshAuthFailed: "sshAuthFailed"
        case .hostKeyMismatch: "hostKeyMismatch"
        case .dockerMissing: "dockerMissing"
        case .gitMissing: "gitMissing"
        case .installFailed: "installFailed"
        case .healthTimeout: "healthTimeout"
        case .serviceAuthFailed: "serviceAuthFailed"
        case .apiRejected: "apiRejected"
        case .unknownOutcome: "unknownOutcome"
        case .invalidResponse: "invalidResponse"
        case .tooLarge: "tooLarge"
        case .storage: "storage"
        case .invalidInput: "invalidInput"
        }
    }
}
