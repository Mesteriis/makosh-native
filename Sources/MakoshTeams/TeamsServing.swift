import Foundation
import MakoshCore

/// The concrete Teams boundary. Protocol/cache/key/file work remains in the service's actors.
public protocol TeamsServing: TeamsNotificationServing {
    func load(configuration: ContactWorkspaceConfiguration) async throws -> [TeamsAccount]
    func addAccount(name: String, configuration: TeamsOAuthConfiguration, readOnly: Bool) async throws -> TeamsAccount
    func beginAuthorization(accountID: UUID, method: TeamsAuthorizationMethod, capabilities: Set<TeamsCapability>) async throws -> TeamsAuthorizationPresentation
    func authorizationStatus(accountID: UUID) async throws -> TeamsAuthorizationPresentation
    func cancelAuthorization(accountID: UUID) async throws
    func connect(accountID: UUID) async throws
    func disconnect(accountID: UUID) async throws
    func synchronize(accountID: UUID) async throws
    func snapshot(accountID: UUID) async throws -> TeamsWorkspaceSnapshot
    func messages(scope: TeamsScope, before: TeamsRetainedCursor?) async throws -> TeamsRetainedPage
    func search(scope: TeamsScope, query: String, before: TeamsRetainedCursor?) async throws -> TeamsRetainedPage
    func archivePage(scope: TeamsScope, before: Int64?) async throws -> [MessageArchiveRecord]
    func send(scope: TeamsScope, content: TeamsDraft) async throws -> TeamsOutgoing
    func resumeOutgoing(accountID: UUID, id: UUID) async throws -> TeamsOutgoing
    func copyOutgoing(accountID: UUID, id: UUID) async throws -> TeamsOutgoing
    func resolveOutgoing(accountID: UUID, id: UUID, sent: Bool) async throws -> TeamsOutgoing
    func outgoingPage(accountID: UUID, before: TeamsOutgoingCursor?) async throws -> TeamsOutgoingPage
    func configureFiles(storage: S3ObjectStoreConfiguration, spoolDirectory: URL) async throws
    func prepareFiles(scope: TeamsScope, files: [URL]) async throws -> [TeamsPreparedFile]
    func fileFolders(scope: TeamsScope, parentID: String?, continuation: TeamsContinuation?) async throws -> TeamsDriveFolderPage
    func fileAccessPlan(scope: TeamsScope, fileIDs: [UUID], destination: TeamsFileDestination) async throws -> TeamsFileAccessPlan
    func sendFiles(scope: TeamsScope, content: TeamsDraft, accessPlan: TeamsFileAccessPlan) async throws -> TeamsOutgoing
    func download(scope: TeamsScope, messageID: String, attachmentID: String, version: String?) async throws -> TeamsFileLease
    func exportArchive(scope: TeamsScope) async throws -> TeamsFileLease
    func savingFiles(scope: TeamsScope) async throws -> Bool
    func setSavingFiles(scope: TeamsScope, enabled: Bool) async throws
    func localUnreadCount(scope: TeamsScope) async throws -> Int
    func shutdown() async
}
extension TeamsWorker: TeamsServing {}
