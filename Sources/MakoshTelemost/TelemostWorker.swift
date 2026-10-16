import Foundation
import MakoshCore

public actor TelemostWorker: TelemostServing {
    let repository: TelemostRepository
    let api: TelemostAPI
    let oauth: TelemostOAuth
    let vault: any TelemostTokenStoring
    let now: @Sendable () -> Date
    let contacts: ContactWorkspaceWorker?
    var tokens: [UUID: TelemostToken] = [:]
    var credentialEpochs: [UUID: UUID] = [:]
    struct ActiveCredential { let token: TelemostToken; let epoch: UUID?; var accessToken: String { token.accessToken } }
    var connections: [UUID: TelemostConnectionState] = [:]
    var generations: [UUID: UInt64] = [:]
    struct AuthTicket { let lease: TelemostLease; let generation: UInt64; let request: TelemostAuthorizationRequest }
    var authTickets: [UUID: AuthTicket] = [:]
    var authInstallations: Set<UUID> = []
    var closing = false
    var closed = false
    var activeWork = 0
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
    var syntheticEvidence = false
    var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(repository: TelemostRepository = TelemostRepository(), api: TelemostAPI = TelemostAPI(),
                oauth: TelemostOAuth = TelemostOAuth(), vault: any TelemostTokenStoring = TelemostTokenVault(),
                now: @escaping @Sendable () -> Date = Date.init, contacts: ContactWorkspaceWorker? = nil) {
        self.repository = repository; self.api = api; self.oauth = oauth; self.vault = vault; self.now = now; self.contacts = contacts
    }
    public func open(configuration: ContactWorkspaceConfiguration) async throws {
        guard !closing else { throw TelemostFailure.storage }
        try await repository.open(configuration: configuration)
    }
    public func snapshot() async throws -> TelemostWorkspaceSnapshot {
        guard !closing else { throw TelemostFailure.storage }
        let accounts = try await repository.accounts()
        var operations: [TelemostOperation] = [], gates: [UUID: TelemostCredentialGate] = [:]
        for account in accounts {
            operations.append(contentsOf: try await repository.operations(accountID: account.id))
            gates[account.id] = try await repository.credentialGate(accountID: account.id)
        }
        let pending = try await repository.pendingDossierReferences()
        guard !closing else { throw TelemostFailure.storage }
        for (id, token) in tokens where token.expiresAt <= now() { connections[id] = .expired }
        for (id, gate) in gates where gate.requiresLogin || (tokens[id] != nil && credentialEpochs[id] != gate.epoch) { connections[id] = .expired }
        let granted = tokens.filter { $0.value.expiresAt > now() && gates[$0.key]?.requiresLogin == false && credentialEpochs[$0.key] == gates[$0.key]?.epoch }.mapValues(\.capabilities)
        return .init(accounts: accounts, connections: connections.mapValues { syntheticEvidence && ($0 == .connected || $0 == .authorized) ? .synthetic : $0 }, operations: operations.sorted { $0.createdAt > $1.createdAt },
                     pendingDossier: pending, grantedCapabilities: granted)
    }
    func admitWork() throws { guard !closing else { throw TelemostFailure.storage }; activeWork += 1 }
    func finishWork() {
        activeWork -= 1
        if activeWork == 0 { let values = drainWaiters; drainWaiters = []; values.forEach { $0.resume() } }
    }
    func generation(_ id: UUID) -> UInt64 { generations[id, default: 0] }
    func requireCurrent(_ id: UUID, _ value: UInt64) throws {
        guard !closing, generation(id) == value else { throw CancellationError() }
        try Task.checkCancellation()
    }
    func credential(accountID: UUID, capability: TelemostCapability) async throws -> ActiveCredential {
        guard let token = tokens[accountID] else { throw TelemostFailure.unauthorized }
        guard token.expiresAt > now() else { connections[accountID] = .expired; throw TelemostFailure.expired }
        let generation = generation(accountID), account = try await repository.account(id: accountID)
        try requireCurrent(accountID, generation)
        guard account.principal?.sameSource(as: token.principal) == true else { throw TelemostFailure.conflict }
        guard account.capabilities.contains(capability), token.capabilities.contains(capability) else { throw TelemostFailure.scopeDenied }
        let gate = try await repository.credentialGate(accountID: accountID)
        try requireCurrent(accountID, generation)
        guard !gate.requiresLogin, credentialEpochs[accountID] == gate.epoch else { tokens[accountID] = nil; connections[accountID] = .expired; throw TelemostFailure.expired }
        return .init(token: token, epoch: gate.epoch)
    }
    func validateCredential(_ credential: ActiveCredential, accountID: UUID) async throws {
        let gate = try await repository.credentialGate(accountID: accountID)
        guard !gate.requiresLogin, gate.epoch == credential.epoch else { throw TelemostFailure.expired }
    }
    func retainCredentialRejection(_ error: any Error, accountID: UUID, credential: ActiveCredential, lease: TelemostLease, generation: UInt64) async throws {
        guard error as? TelemostFailure == .unauthorized else { return }
        if self.generation(accountID) == generation { tokens[accountID] = nil; credentialEpochs[accountID] = nil }
        _ = try await repository.rejectCredential(accountID: accountID, epoch: credential.epoch, lease: lease)
    }
    func publishFailure(_ error: any Error, accountID: UUID, generation: UInt64) {
        if !closing, self.generation(accountID) == generation {
            let failure = error as? TelemostFailure ?? .transport
            connections[accountID] = failure == .expired || (failure == .unauthorized && tokens[accountID] == nil) ? .expired : .failed(failure)
        }
    }
    public func addAccount(_ account: TelemostAccount) async throws {
        guard !closing, account.principal == nil else { throw TelemostFailure.invalidConfiguration }
        do {
            _ = try await repository.account(id: account.id)
            let lease = try await repository.acquireLease(accountID: account.id, operationID: UUID(), kind: .auth)
            do { try await repository.saveAccount(account); try await repository.releaseLease(lease) }
            catch { try? await repository.releaseLease(lease); throw error }
        } catch TelemostFailure.missing { try await repository.saveAccount(account) }
    }
    public func addLink(_ url: TelemostMeetingURL, accountID: UUID?) async throws -> UUID {
        guard !closing else { throw TelemostFailure.storage }
        return try await repository.addLink(url, accountID: accountID)
    }
    public func page(accountID: UUID?, query: String, before: TelemostHistoryCursor?, limit: Int) async throws -> TelemostMeetingPage {
        guard !closing else { throw TelemostFailure.storage }
        return try await repository.page(accountID: accountID, query: query, before: before, limit: limit)
    }
    public func saveLocal(_ meeting: TelemostLocalMeeting) async throws { guard !closing else { throw TelemostFailure.storage }; try await repository.saveLocal(meeting) }
    public func versions(meetingID: UUID, before: Int64?, limit: Int) async throws -> [TelemostRetainedVersion] {
        try await repository.versions(meetingID: meetingID, before: before, limit: limit)
    }
    public func export(accountID: UUID?, to url: URL) async throws -> Int {
        try admitWork(); defer { finishWork() }
        return try await repository.export(accountID: accountID, to: url)
    }
    public func create(accountID: UUID, request: TelemostCreateRequest) async throws -> UUID { try await submit(accountID: accountID, payload: .create(request)) }
    public func update(scope: TelemostScope, patch: TelemostMeetingPatch) async throws -> UUID { try await submit(accountID: scope.accountID, payload: .update(scope, patch)) }
    private func submit(accountID: UUID, payload: TelemostOperationPayload) async throws -> UUID {
        try admitWork(); defer { finishWork() }
        let operation = TelemostOperation(accountID: accountID, payload: payload), generation = generation(accountID)
        let capability: TelemostCapability = payload.scope == nil ? .create : .update
        let token = try await credential(accountID: accountID, capability: capability)
        let lease = try await repository.acquireLease(accountID: accountID, operationID: operation.id, kind: .dispatch)
        do {
            try await validateCredential(token, accountID: accountID)
            try requireCurrent(accountID, generation)
            try await repository.prepare(operation)
            _ = try await repository.begin(operationID: operation.id, attemptID: operation.attemptID)
            let outcome: TelemostOperationOutcome
            do {
                try requireCurrent(accountID, generation)
                switch payload {
                case .create(let request): outcome = .accepted(try await api.create(accountID: accountID, request: request, token: token.accessToken))
                case .update(let scope, let patch): outcome = .accepted(try await api.update(scope: scope, patch: patch, token: token.accessToken))
                }
            } catch {
                let failure = error as? TelemostFailure ?? .transport
                switch failure {
                case .unauthorized: outcome = .rejected(401)
                case .forbidden: outcome = .rejected(403)
                case .missing: outcome = .rejected(404)
                case .provider(let status) where (400..<500).contains(status) && status != 408 && status != 429: outcome = .rejected(status)
                default: outcome = .unknown
                }
                try await retainCredentialRejection(error, accountID: accountID, credential: token, lease: lease, generation: generation)
                publishFailure(error, accountID: accountID, generation: generation)
            }
            // Publication may be revoked; the exact admitted receipt must still become durable.
            try await repository.settle(operationID: operation.id, attemptID: operation.attemptID, outcome: outcome)
            if case .accepted = outcome, !closing, self.generation(accountID) == generation { connections[accountID] = .connected }
            try await repository.releaseLease(lease); return operation.id
        } catch { try? await repository.releaseLease(lease); throw error }
    }
    public func refresh(scope: TelemostScope) async throws {
        try admitWork(); defer { finishWork() }
        let generation = generation(scope.accountID), token = try await credential(accountID: scope.accountID, capability: .read)
        let lease = try await repository.acquireLease(accountID: scope.accountID, operationID: UUID(), kind: .refreshKnown)
        do {
            try await validateCredential(token, accountID: scope.accountID)
            try requireCurrent(scope.accountID, generation)
            let conference = try await api.conference(scope: scope, token: token.accessToken)
            try requireCurrent(scope.accountID, generation)
            try await repository.retain(conference)
            var progress = try await repository.cohostProgress(scope: scope)
            for _ in 0..<20 {
                try requireCurrent(scope.accountID, generation)
                let page = try await api.cohosts(scope: scope, offset: progress.offset, limit: 50, token: token.accessToken)
                try requireCurrent(scope.accountID, generation)
                try await repository.retainCohostPage(page, staged: progress.values)
                if page.complete { connections[scope.accountID] = .connected; try await repository.releaseLease(lease); return }
                progress = (progress.offset + page.emails.count, progress.values + page.emails)
            }
            throw TelemostFailure.incomplete
        } catch {
            if let failure = error as? TelemostFailure, failure == .missing || failure == .forbidden {
                try? await repository.markUnavailable(scope: scope)
            }
            do { try await retainCredentialRejection(error, accountID: scope.accountID, credential: token, lease: lease, generation: generation) }
            catch { try? await repository.releaseLease(lease); throw error }
            publishFailure(error, accountID: scope.accountID, generation: generation)
            try? await repository.releaseLease(lease); throw error
        }
    }
    public func resolve(operationID: UUID, resolution: TelemostResolution) async throws {
        try admitWork(); defer { finishWork() }
        let operation = try await repository.operation(id: operationID)
        guard operation.state == .unknown else { throw TelemostFailure.conflict }
        let generation = generation(operation.accountID)
        let lease = try await repository.acquireLease(accountID: operation.accountID, operationID: operationID, kind: .dispatch)
        do {
            try requireCurrent(operation.accountID, generation)
            switch resolution {
            case .dismissUnknownAndAllowNewAttempt:
                guard operation.payload.scope == nil else { throw TelemostFailure.conflict }
                try await repository.resolveUnknown(operationID: operationID)
            case .attachVerifiedMeetingURL(let url):
                let token = try await credential(accountID: operation.accountID, capability: .read)
                let scope = TelemostScope(accountID: operation.accountID, conferenceID: url.conferenceID)
                guard operation.payload.scope.map({ $0 == scope }) ?? true else { throw TelemostFailure.conflict }
                try await validateCredential(token, accountID: operation.accountID)
                try requireCurrent(operation.accountID, generation)
                let conference: TelemostConference
                do { conference = try await api.conference(scope: scope, token: token.accessToken) }
                catch {
                    try await retainCredentialRejection(error, accountID: operation.accountID, credential: token, lease: lease, generation: generation)
                    publishFailure(error, accountID: operation.accountID, generation: generation); throw error
                }
                try requireCurrent(operation.accountID, generation)
                try await repository.resolveUnknown(operationID: operationID, receipt: conference)
            }
            try await repository.releaseLease(lease)
        } catch { try? await repository.releaseLease(lease); throw error }
    }
    public func close() async {
        if closed { return }
        if closing { await withCheckedContinuation { closeWaiters.append($0) }; return }
        closing = true
        for id in Array(generations.keys) { generations[id, default: 0] += 1 }
        for id in Array(authTickets.keys) { await cancelAuthorization(id: id) }
        tokens.removeAll(); credentialEpochs.removeAll()
        if activeWork > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
        await repository.close(); closed = true
        let waiters = closeWaiters; closeWaiters = []; waiters.forEach { $0.resume() }
    }
}
