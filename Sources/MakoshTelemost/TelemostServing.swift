import Foundation
import MakoshCore

public enum TelemostConnectionState: Equatable, Sendable {
    case synthetic, disconnected, authorizing, confirmation, authorized, connected, expired, failed(TelemostFailure)
    public var title: String {
        switch self {
        case .synthetic: "QA: подставной API · Яндекс не подключён"
        case .disconnected: "Не подключено"; case .authorizing: "Вход…"; case .confirmation: "Подтвердите аккаунт"
        case .authorized: "Доступ сохранён; API ещё не проверен"; case .connected: "API доступен"
        case .expired: "Нужен повторный вход"; case .failed(let error): error.localizedDescription
        }
    }
}
public struct TelemostWorkspaceSnapshot: Sendable {
    public let accounts: [TelemostAccount]
    public let connections: [UUID: TelemostConnectionState]
    public let operations: [TelemostOperation]
    public let pendingDossier: [TelemostDossierJob]
    public let grantedCapabilities: [UUID: Set<TelemostCapability>]
    public init(accounts: [TelemostAccount] = [], connections: [UUID: TelemostConnectionState] = [:], operations: [TelemostOperation] = [],
                pendingDossier: [TelemostDossierJob] = [], grantedCapabilities: [UUID: Set<TelemostCapability>] = [:]) {
        self.accounts = accounts; self.connections = connections; self.operations = operations
        self.pendingDossier = pendingDossier; self.grantedCapabilities = grantedCapabilities
    }
}
public enum TelemostResolution: Sendable { case attachVerifiedMeetingURL(TelemostMeetingURL), dismissUnknownAndAllowNewAttempt }
public protocol TelemostServing: Sendable {
    func open(configuration: ContactWorkspaceConfiguration) async throws
    func snapshot() async throws -> TelemostWorkspaceSnapshot
    func addAccount(_ account: TelemostAccount) async throws
    func authorize(accountID: UUID, mode: TelemostAuthorizationMode) async throws -> TelemostAuthorizationRequest
    func completeAuthorization(id: UUID, callback: URL) async throws -> TelemostGrantResult
    func completeAuthorization(id: UUID, code: String) async throws -> TelemostGrantResult
    func confirmGrant(_ grant: TelemostGrantResult, accountID: UUID) async throws
    func cancelAuthorization(id: UUID) async
    func connect(accountID: UUID) async throws
    func disconnect(accountID: UUID) async
    func addLink(_ url: TelemostMeetingURL, accountID: UUID?) async throws -> UUID
    func refresh(scope: TelemostScope) async throws
    func create(accountID: UUID, request: TelemostCreateRequest) async throws -> UUID
    func update(scope: TelemostScope, patch: TelemostMeetingPatch) async throws -> UUID
    func resolve(operationID: UUID, resolution: TelemostResolution) async throws
    func page(accountID: UUID?, query: String, before: TelemostHistoryCursor?, limit: Int) async throws -> TelemostMeetingPage
    func saveLocal(_ meeting: TelemostLocalMeeting) async throws
    func versions(meetingID: UUID, before: Int64?, limit: Int) async throws -> [TelemostRetainedVersion]
    func export(accountID: UUID?, to url: URL) async throws -> Int
    func close() async
    func linkDossier(meetingID: UUID, contactID: UUID) async throws -> UUID
}
