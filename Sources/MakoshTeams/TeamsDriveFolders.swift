import Foundation

public struct TeamsDriveFolderChoice: Identifiable, Sendable {
    public let id: String
    public let name: String
}
public struct TeamsDriveFolderPage: Sendable {
    public let parent: TeamsDriveFolderChoice
    public let values: [TeamsDriveFolderChoice]
    public let next: TeamsContinuation?
}
extension TeamsGraphFiles {
    func folders(parentID: String?, continuation: TeamsContinuation?, token: String, capabilities: Set<TeamsCapability>) async throws -> TeamsDriveFolderPage {
        guard Self.canRead(capabilities) else { throw TeamsFailure.forbidden }
        let item = try await get(TeamsDriveItem.self, components: ["me", "drive"] + (parentID.map { ["items", $0] } ?? ["root"]), token: token)
        guard item.folder != nil, item.remoteItem == nil else { throw TeamsFailure.invalidResponse }
        let collection = TeamsCollection(context: context, kind: .driveFolders(parentID))
        let page = try await graph.page(TeamsDriveItem.self, collection: collection, continuation: continuation, token: token)
        if let failure = page.continuationFailure { throw failure }
        return TeamsDriveFolderPage(parent: .init(id: item.id, name: item.name), values: page.values.filter { $0.folder != nil && $0.remoteItem == nil }.map { .init(id: $0.id, name: $0.name) }, next: page.next)
    }
}
extension TeamsWorker {
    public func fileFolders(scope: TeamsScope, parentID: String?, continuation: TeamsContinuation?) async throws -> TeamsDriveFolderPage {
        let (session, generation) = try await sendingSession(scope: scope)
        let token = try await session.token(), capabilities = try await session.capabilities()
        let authorize: @Sendable () async throws -> Void = { try await self.check(accountID: scope.accountID, generation: generation) }
        let graph = TeamsGraphFiles(context: session.context, transport: TeamsAuthorizedTransport(base: transport, authorize: authorize))
        let result = try await graph.folders(parentID: parentID, continuation: continuation, token: token, capabilities: capabilities)
        try check(accountID: scope.accountID, generation: generation); return result
    }
}
