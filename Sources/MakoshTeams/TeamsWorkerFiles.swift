import Foundation
import MakoshCore

struct TeamsAuthorizedTransport: TeamsHTTPTransport {
    let base: any TeamsHTTPTransport
    let authorize: @Sendable () async throws -> Void
    func response(to request: URLRequest) async throws -> TeamsHTTPResponse { try await authorize(); return try await base.response(to: request) }
    func upload(file: URL, to request: URLRequest) async throws -> TeamsHTTPResponse { try await authorize(); return try await base.upload(file: file, to: request) }
}
struct TeamsAuthorizedDownloader: TeamsFileDownloading {
    let base: any TeamsFileDownloading
    let authorize: @Sendable () async throws -> Void
    func download(_ request: URLRequest, to destination: URL, maximumBytes: Int64) async throws -> TeamsFileDownloadResponse {
        try await authorize(); return try await base.download(request, to: destination, maximumBytes: maximumBytes)
    }
}
extension TeamsWorker {
    public func configureFiles(storage: S3ObjectStoreConfiguration, spoolDirectory: URL) throws {
        try check()
        if syntheticMode, !TeamsQAIsolation.localEndpoint(storage.endpoint) { throw TeamsFailure.invalidConfiguration }
        guard let configuration, fileService == nil else { throw TeamsFailure.invalidConfiguration }
        fileService = TeamsFiles(configuration: configuration, repository: repository, storage: storage, spoolDirectory: spoolDirectory, keyProvider: repository.keyProvider)
    }
    func files() throws -> TeamsFiles { try check(); guard let fileService else { throw TeamsFailure.invalidConfiguration }; return fileService }
    public func savingFiles(scope: TeamsScope) async throws -> Bool { try await files().savingFiles(scope: scope) }
    public func setSavingFiles(scope: TeamsScope, enabled: Bool) async throws { try await files().setSavingFiles(scope: scope, enabled: enabled) }
    public func prepareFiles(scope: TeamsScope, files urls: [URL]) async throws -> [TeamsPreparedFile] {
        if syntheticMode, !urls.allSatisfy({ TeamsQAIsolation.permitsFile($0, root: syntheticFileRoot) }) { throw TeamsFailure.invalidResource }
        try beginMutation(); defer { finishMutation() }
        return try await files().prepare(scope: scope, files: urls)
    }
    public func fileAccessPlan(scope: TeamsScope, fileIDs: [UUID], destination: TeamsFileDestination) async throws -> TeamsFileAccessPlan {
        let (session, generation) = try await sendingSession(scope: scope)
        _ = try await files().prepared(scope: scope, ids: fileIDs)
        let token = try await session.token(), capabilities = try await session.capabilities()
        let authorize: @Sendable () async throws -> Void = { try await self.check(accountID: scope.accountID, generation: generation) }
        let graph = TeamsGraphFiles(context: session.context, transport: TeamsAuthorizedTransport(base: transport, authorize: authorize))
        let roster = try await graph.roster(scope: scope, token: token, capabilities: capabilities)
        let folder = try await graph.folder(destination: destination, roster: roster, token: token, capabilities: capabilities)
        let plan = TeamsFileAccessPlan(id: UUID(), scope: scope, fileIDs: fileIDs, destination: destination, folder: folder, roster: roster)
        try check(accountID: scope.accountID, generation: generation)
        try await repository.saveFilePlan(plan)
        try check(accountID: scope.accountID, generation: generation); return plan
    }
    public func sendFiles(scope: TeamsScope, content: TeamsDraft, accessPlan: TeamsFileAccessPlan) async throws -> TeamsOutgoing {
        guard accessPlan.scope == scope, accessPlan.fileIDs == content.fileIDs else { throw TeamsFailure.invalidResource }
        let (_, generation) = try await sendingSession(scope: scope)
        try check(accountID: scope.accountID, generation: generation)
        let outgoing = try await repository.prepareFileOutgoing(scope: scope, content: content, planID: accessPlan.id)
        try check(accountID: scope.accountID, generation: generation)
        return try await resumeOutgoing(accountID: scope.accountID, id: outgoing.id)
    }
    public func download(scope: TeamsScope, messageID: String, attachmentID: String, version: String?) async throws -> TeamsFileLease {
        try check()
        let job = try await repository.incomingFile(scope: scope, messageID: messageID, attachmentID: attachmentID, version: version)
        guard let principal = try await repository.validate(scope).verifiedPrincipal else { throw TeamsFailure.principalChanged }
        let session = sessions[scope.accountID], generation = generations[scope.accountID]
        let token = try await session?.token() ?? "", capabilities = try await session?.capabilities() ?? []
        let authorize: @Sendable () async throws -> Void = { try await self.checkRead(accountID: scope.accountID, generation: generation); guard generation != nil else { throw TeamsFailure.signInRequired } }
        let graph = TeamsGraphFiles(context: TeamsAccountContext(accountID: scope.accountID, principal: principal), transport: TeamsAuthorizedTransport(base: transport, authorize: authorize))
        try beginMutation(); defer { finishMutation() }
        let lease = try await files().download(job: job, graph: graph, token: token, capabilities: capabilities,
            downloader: TeamsAuthorizedDownloader(base: fileDownloader, authorize: authorize))
        do { try checkRead(accountID: scope.accountID, generation: generation); return lease }
        catch { await lease.release(); throw error }
    }
    public func exportArchive(scope: TeamsScope) async throws -> TeamsFileLease {
        try check(); guard let projection else { throw TeamsFailure.storage }
        try beginMutation(); defer { finishMutation() }
        let lease = try await projection.export(scope: scope)
        do { try check(); return lease } catch { await lease.release(); throw error }
    }
}
