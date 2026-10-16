import Foundation

/// A concrete Teams lifetime permit. The synchronous Keychain admission check and write share its lock.
final class TeamsAuthorizationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func cancel() { lock.withLock { active = false } }
    func perform<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock { guard active else { throw CancellationError() }; return try operation() }
    }
}

actor TeamsSession {
    let context: TeamsAccountContext
    let graph: TeamsGraphClient
    private let configuration: TeamsOAuthConfiguration
    private let repository: TeamsRepository
    private let vault: any TeamsTokenStoring
    private let oauth: TeamsOAuthClient
    private let permit = TeamsAuthorizationPermit()
    private var closed = false
    init(context: TeamsAccountContext, configuration: TeamsOAuthConfiguration, repository: TeamsRepository,
         vault: any TeamsTokenStoring, transport: any TeamsHTTPTransport) {
        self.context = context; self.configuration = configuration; self.repository = repository; self.vault = vault
        graph = TeamsGraphClient(context: context, transport: transport); oauth = TeamsOAuthClient(transport: transport)
    }
    private func check() throws { try Task.checkCancellation(); guard !closed else { throw CancellationError() } }
    func token() async throws -> String {
        try check()
        guard var bundle = try await vault.load(accountID: context.accountID) else { throw TeamsFailure.signInRequired }
        try check()
        if bundle.expiresAt.timeIntervalSinceNow > 60 { return bundle.accessToken }
        let lease = try await repository.acquireLease(kind: .refresh, accountID: context.accountID, operationID: UUID())
        do {
            try check()
            guard let current = try await vault.load(accountID: context.accountID) else { throw TeamsFailure.signInRequired }
            bundle = current
            try check()
            if bundle.expiresAt.timeIntervalSinceNow <= 60 {
                let updated = try await oauth.refresh(bundle: bundle, configuration: configuration)
                try check()
                let verified = try await oauth.verifyIdentity(bundle: updated, configuration: configuration, expected: context.principal)
                try check()
                try await vault.save(verified.bundle, accountID: context.accountID, permit: permit)
                try check()
                bundle = verified.bundle
            }
            try await repository.releaseLease(lease)
            try check()
            return bundle.accessToken
        } catch { try? await repository.releaseLease(lease); throw error }
    }
    func capabilities() async throws -> Set<TeamsCapability> {
        try check()
        guard let bundle = try await vault.load(accountID: context.accountID) else { throw TeamsFailure.signInRequired }
        try check()
        return Self.capabilities(bundle.grantedScopes)
    }
    static func capabilities(_ scopes: Set<String>) -> Set<TeamsCapability> {
        Set(TeamsCapability.allCases.filter { capability in
            if capability == .basicChats { return scopes.isSuperset(of: ["Chat.Read", "User.Read"]) }
            return scopes.isSuperset(of: capability.scopes)
        })
    }
    func close() { closed = true; permit.cancel() }
}
