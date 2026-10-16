import Foundation

public struct TeamsFileAccessPlan: Codable, Identifiable, Sendable {
    public let id: UUID
    public let scope: TeamsScope
    public let fileIDs: [UUID]
    public let destination: TeamsFileDestination
    let folder: TeamsFileFolder
    let roster: TeamsFileRoster
    public var recipients: [TeamsFileRecipient] { roster.recipients }
    public var folderName: String { folder.name }
}
public struct TeamsFileSubmissionState: Codable, Sendable {
    public struct Stage: Codable, Sendable {
        public enum State: String, Codable, Sendable { case uploading, uploaded, granting, granted, verifyingInheritance, inherited, publishing }
        public let fileID: UUID
        public let attemptID: UUID
        public let state: State
        public let remote: TeamsRemoteFile?
    }
    public let plan: TeamsFileAccessPlan
    public var stages: [Stage]
}

extension TeamsRepository {
    func saveFilePlan(_ plan: TeamsFileAccessPlan) throws {
        _ = try validate(plan.scope)
        guard !plan.fileIDs.isEmpty, plan.fileIDs.count <= 10, plan.roster.scope == plan.scope.policyScope else { throw TeamsFailure.invalidResource }
        _ = try preparedFiles(scope: plan.scope, ids: plan.fileIDs)
        let db = try db(), token = try db.token(["file-plan", plan.id.uuidString])
        _ = try db.query("INSERT INTO \(db.prefix)teams_file_plans VALUES($1,$2,NULL,$3)", [token, try db.token(plan.scope.storageKey), try db.seal(plan, token: "file-plan:" + token)])
    }
    func filePlan(id: UUID, scope: TeamsScope) throws -> TeamsFileAccessPlan {
        _ = try validate(scope)
        let db = try db(), token = try db.token(["file-plan", id.uuidString])
        guard let row = try db.query("SELECT ciphertext FROM \(db.prefix)teams_file_plans WHERE token=$1 AND scope=$2", [token, try db.token(scope.storageKey)]).first else { throw TeamsFailure.invalidResource }
        let value: TeamsFileAccessPlan = try db.decode(row[0], token: "file-plan:" + token)
        guard value.id == id, value.scope == scope else { throw TeamsFailure.storage }; return value
    }
    func prepareFileOutgoing(scope: TeamsScope, content: TeamsDraft, planID: UUID) throws -> TeamsOutgoing {
        let db = try db()
        return try db.transaction {
            let plan = try filePlan(id: planID, scope: scope)
            guard content.fileIDs == plan.fileIDs else { throw TeamsFailure.invalidResource }
            let value = try prepare(scope: scope, content: content, filePlan: plan)
            guard try db.query("UPDATE \(db.prefix)teams_file_plans SET outgoing=$2::uuid WHERE token=$1 AND outgoing IS NULL RETURNING token", [try db.token(["file-plan", planID.uuidString]), value.id.uuidString]).count == 1 else { throw TeamsFailure.uncertainSubmission }
            return value
        }
    }
    func recordFileStage(outgoing: TeamsOutgoing, fileID: UUID, state: TeamsFileSubmissionState.Stage.State, remote: TeamsRemoteFile?) throws {
        guard let attempt = outgoing.attemptID, let lease = outgoingLeases[outgoing.id], lease.operationID == attempt else { throw TeamsFailure.operationBusy }
        try db().transaction {
            var value = try outgoingRaw(id: outgoing.id, accountID: outgoing.scope.accountID, lock: true)
            guard value.state == .dispatching, value.attemptID == attempt, value.ownerID == lease.id,
                  value.fileSubmission?.plan.fileIDs.contains(fileID) == true else { throw TeamsFailure.operationBusy }
            value.fileSubmission?.stages.append(.init(fileID: fileID, attemptID: UUID(), state: state, remote: remote))
            try storeOutgoing(value)
        }
    }
}

actor TeamsFileSubmission {
    let repository: TeamsRepository
    let files: TeamsFiles
    let graph: TeamsGraphFiles
    init(repository: TeamsRepository, files: TeamsFiles, graph: TeamsGraphFiles) { self.repository = repository; self.files = files; self.graph = graph }
    func dispatch(_ outgoing: TeamsOutgoing, token: String, capabilities: Set<TeamsCapability>,
                  authorize: @escaping @Sendable () async throws -> Void) async throws -> TeamsOutgoing {
        guard let submission = outgoing.fileSubmission, submission.stages.isEmpty, let attempt = outgoing.attemptID else { throw TeamsFailure.uncertainSubmission }
        let plan = submission.plan
        let outcome: TeamsAttemptOutcome
        do {
            try await authorize()
            try await graph.recheckRoster(plan.roster, scope: outgoing.scope, token: token, capabilities: capabilities)
            let folder = try await graph.folder(destination: plan.destination, roster: plan.roster, token: token, capabilities: capabilities)
            guard folder.driveID == plan.folder.driveID, folder.itemID == plan.folder.itemID else { throw TeamsFailure.invalidResource }
            let prepared = try await files.prepared(scope: outgoing.scope, ids: outgoing.content.fileIDs)
            var remotes: [TeamsRemoteFile] = []
            for file in prepared {
                try await authorize()
                let lease = try await files.openPrepared(scope: outgoing.scope, id: file.id)
                let remote: TeamsRemoteFile
                do {
                    try await repository.recordFileStage(outgoing: outgoing, fileID: file.id, state: .uploading, remote: nil)
                    try await authorize()
                    remote = try await graph.upload(file, from: lease.url, folder: folder, targetID: UUID(), token: token, capabilities: capabilities)
                    try await repository.recordFileStage(outgoing: outgoing, fileID: file.id, state: .uploaded, remote: remote)
                    await lease.release()
                } catch { await lease.release(); throw error }
                try await authorize()
                try await graph.recheckRoster(plan.roster, scope: outgoing.scope, token: token, capabilities: capabilities)
                _ = try await graph.folder(destination: plan.destination, roster: plan.roster, token: token, capabilities: capabilities)
                switch plan.destination {
                case .ownDrive:
                    try await repository.recordFileStage(outgoing: outgoing, fileID: file.id, state: .granting, remote: remote)
                    try await authorize()
                    if !plan.recipients.isEmpty { try await graph.grantRead(remote, recipients: plan.recipients, token: token, capabilities: capabilities) }
                    try await repository.recordFileStage(outgoing: outgoing, fileID: file.id, state: .granted, remote: remote)
                case .channel:
                    try await repository.recordFileStage(outgoing: outgoing, fileID: file.id, state: .verifyingInheritance, remote: remote)
                    try await authorize()
                    try await graph.verifyInheritedRead(remote, folder: folder, roster: plan.roster, token: token, capabilities: capabilities)
                    try await repository.recordFileStage(outgoing: outgoing, fileID: file.id, state: .inherited, remote: remote)
                }
                remotes.append(remote)
            }
            try await authorize()
            try await graph.recheckRoster(plan.roster, scope: outgoing.scope, token: token, capabilities: capabilities)
            for (id, remote) in zip(plan.fileIDs, remotes) { try await repository.recordFileStage(outgoing: outgoing, fileID: id, state: .publishing, remote: remote) }
            try await authorize()
            outcome = .accepted(try await graph.graph.postFileMessage(scope: outgoing.scope, content: outgoing.content, remotes: remotes, token: token))
        } catch { outcome = .unknown }
        return try await repository.settleOutgoing(id: outgoing.id, accountID: outgoing.scope.accountID, attemptID: attempt, outcome: outcome)
    }
}
