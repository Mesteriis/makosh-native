import Foundation
import MakoshCore
@testable import MakoshTeams

/// Delays only the external completion boundary; all persistence/session behavior is the real worker.
actor TeamsModelFixture: TeamsServing {
    let base: TeamsWorker
    private var historyHeld = false, policyHeld = false, preparationHeld = false
    private var held: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(base: TeamsWorker) { self.base = base }
    func holdPreparation() { preparationHeld = true }
    func holdHistory() { historyHeld = true }
    func holdFilePolicy() { policyHeld = true }
    func waitForHeld() async { if held != nil { return }; await withCheckedContinuation { observer = $0 } }
    func releaseHeld() { held?.resume(); held = nil }
    private func pause() async { await withCheckedContinuation { held = $0; observer?.resume(); observer = nil } }
    func load(configuration: ContactWorkspaceConfiguration) async throws -> [TeamsAccount] { try await base.load(configuration: configuration) }
    func addAccount(name: String, configuration: TeamsOAuthConfiguration, readOnly: Bool) async throws -> TeamsAccount { try await base.addAccount(name: name, configuration: configuration, readOnly: readOnly) }
    func beginAuthorization(accountID: UUID, method: TeamsAuthorizationMethod, capabilities: Set<TeamsCapability>) async throws -> TeamsAuthorizationPresentation { try await base.beginAuthorization(accountID: accountID, method: method, capabilities: capabilities) }
    func authorizationStatus(accountID: UUID) async throws -> TeamsAuthorizationPresentation { try await base.authorizationStatus(accountID: accountID) }
    func cancelAuthorization(accountID: UUID) async throws { try await base.cancelAuthorization(accountID: accountID) }
    func connect(accountID: UUID) async throws { try await base.connect(accountID: accountID) }
    func disconnect(accountID: UUID) async throws { try await base.disconnect(accountID: accountID) }
    func synchronize(accountID: UUID) async throws { try await base.synchronize(accountID: accountID) }
    func snapshot(accountID: UUID) async throws -> TeamsWorkspaceSnapshot { try await base.snapshot(accountID: accountID) }
    func messages(scope: TeamsScope, before: TeamsRetainedCursor?) async throws -> TeamsRetainedPage {
        let value = try await base.messages(scope: scope, before: before)
        if historyHeld, scope == teamsTestScope { historyHeld = false; await pause() }
        return value
    }
    func search(scope: TeamsScope, query: String, before: TeamsRetainedCursor?) async throws -> TeamsRetainedPage { try await base.search(scope: scope, query: query, before: before) }
    func archivePage(scope: TeamsScope, before: Int64?) async throws -> [MessageArchiveRecord] { try await base.archivePage(scope: scope, before: before) }
    func send(scope: TeamsScope, content: TeamsDraft) async throws -> TeamsOutgoing { try await base.send(scope: scope, content: content) }
    func resumeOutgoing(accountID: UUID, id: UUID) async throws -> TeamsOutgoing { try await base.resumeOutgoing(accountID: accountID, id: id) }
    func copyOutgoing(accountID: UUID, id: UUID) async throws -> TeamsOutgoing { try await base.copyOutgoing(accountID: accountID, id: id) }
    func resolveOutgoing(accountID: UUID, id: UUID, sent: Bool) async throws -> TeamsOutgoing { try await base.resolveOutgoing(accountID: accountID, id: id, sent: sent) }
    func outgoingPage(accountID: UUID, before: TeamsOutgoingCursor?) async throws -> TeamsOutgoingPage { try await base.outgoingPage(accountID: accountID, before: before) }
    func configureFiles(storage: S3ObjectStoreConfiguration, spoolDirectory: URL) async throws { try await base.configureFiles(storage: storage, spoolDirectory: spoolDirectory) }
    func prepareFiles(scope: TeamsScope, files: [URL]) async throws -> [TeamsPreparedFile] { let value = try await base.prepareFiles(scope: scope, files: files); if preparationHeld { preparationHeld = false; await pause() }; return value }
    func fileFolders(scope: TeamsScope, parentID: String?, continuation: TeamsContinuation?) async throws -> TeamsDriveFolderPage { try await base.fileFolders(scope: scope, parentID: parentID, continuation: continuation) }
    func fileAccessPlan(scope: TeamsScope, fileIDs: [UUID], destination: TeamsFileDestination) async throws -> TeamsFileAccessPlan { try await base.fileAccessPlan(scope: scope, fileIDs: fileIDs, destination: destination) }
    func sendFiles(scope: TeamsScope, content: TeamsDraft, accessPlan: TeamsFileAccessPlan) async throws -> TeamsOutgoing { try await base.sendFiles(scope: scope, content: content, accessPlan: accessPlan) }
    func download(scope: TeamsScope, messageID: String, attachmentID: String, version: String?) async throws -> TeamsFileLease { try await base.download(scope: scope, messageID: messageID, attachmentID: attachmentID, version: version) }
    func exportArchive(scope: TeamsScope) async throws -> TeamsFileLease { try await base.exportArchive(scope: scope) }
    func savingFiles(scope: TeamsScope) async throws -> Bool {
        let value = try await base.savingFiles(scope: scope)
        if policyHeld { policyHeld = false; await pause() }; return value
    }
    func setSavingFiles(scope: TeamsScope, enabled: Bool) async throws { try await base.setSavingFiles(scope: scope, enabled: enabled) }
    func savedNotificationRule(scope: TeamsNotificationScope) async throws -> TeamsNotificationRule { try await base.savedNotificationRule(scope: scope) }
    func setNotificationRule(_ rule: TeamsNotificationRule, scope: TeamsNotificationScope) async throws { try await base.setNotificationRule(rule, scope: scope) }
    func notificationRule(conversation: TeamsScope) async throws -> TeamsNotificationRule { try await base.notificationRule(conversation: conversation) }
    func claimNotifications(accountID: UUID) async throws -> [TeamsNotificationEvent] { try await base.claimNotifications(accountID: accountID) }
    func notificationIsCurrent(_ event: TeamsNotificationEvent) async throws -> Bool { try await base.notificationIsCurrent(event) }
    func activateNotification(token: String) async throws -> TeamsNotificationEvent? { try await base.activateNotification(token: token) }
    func markLocallyRead(scope: TeamsScope) async throws { try await base.markLocallyRead(scope: scope) }
    func localUnreadCount(scope: TeamsScope) async throws -> Int { try await base.localUnreadCount(scope: scope) }
    func shutdown() async { await base.shutdown() }
}
