import Foundation
import MakoshCore

public enum TeamsAuthorizationPresentation: Sendable {
    case pending, browser(URL), device(userCode: String, verificationURL: URL, expiresAt: Date, nextPollAt: Date)
    case ready, cancelled, failed(TeamsFailure)
}
public enum TeamsConnectionState: Equatable, Sendable { case disconnected, connecting, connected, synthetic, signInRequired, failed(TeamsFailure) }
public struct TeamsWorkspaceSnapshot: Sendable {
    public let accountID: UUID
    public let principal: TeamsPrincipal?
    public let state: TeamsConnectionState
    public let chats: [TeamsConversation]
    public let teams: [TeamsTeam]
    public let channels: [TeamsChannel]
    public let progress: TeamsSyncProgress
    public let capabilities: Set<TeamsCapability>
}

/// Concrete service conductor. UI never owns tokens, protocol state, SQL, key access or parsing.
public actor TeamsWorker {
    let repository: TeamsRepository
    let transport: any TeamsHTTPTransport
    let vault: any TeamsTokenStoring
    private let oauth: TeamsOAuthClient
    private let automaticSync: Bool
    let syntheticMode: Bool
    let syntheticFileRoot: URL?
    let fileDownloader: any TeamsFileDownloading
    private let pollingClock: any TeamsRetryClock
    var configuration: ContactWorkspaceConfiguration?
    var projection: TeamsArchiveProjection?
    var fileService: TeamsFiles?
    var sessions: [UUID: TeamsSession] = [:]
    private var connectingSessions: [UUID: TeamsSession] = [:]
    private var synchronizers: [UUID: TeamsSynchronization] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    var generations: [UUID: UUID] = [:]
    private var states: [UUID: TeamsConnectionState] = [:]
    private var presentations: [UUID: TeamsAuthorizationPresentation] = [:]
    private enum GrantKind { case browser(TeamsPKCEChallenge, TeamsLoopbackAuthorization), device(TeamsDeviceChallenge) }
    private struct Grant {
        let id: UUID
        let kind: GrantKind
        let permit: TeamsAuthorizationPermit
        var task: Task<Void, Never>?
    }
    private var grants: [UUID: Grant] = [:]
    private var grantGenerations: [UUID: UUID] = [:]
    private var stopped = false
    private var admittedMutations = 0
    private var mutationDrain: [CheckedContinuation<Void, Never>] = []
    func beginMutation() throws { try check(); admittedMutations += 1 }
    func finishMutation() {
        admittedMutations -= 1
        if admittedMutations == 0 {
            let waiting = mutationDrain; mutationDrain.removeAll()
            for continuation in waiting { continuation.resume() }
        }
    }

    public init() {
        repository = TeamsRepository(); transport = TeamsURLSessionTransport(); vault = TeamsTokenVault()
        syntheticMode = false; syntheticFileRoot = nil; fileDownloader = TeamsHTTPSFileDownloader()
        oauth = TeamsOAuthClient(transport: transport); automaticSync = true; pollingClock = TeamsSystemRetryClock()
    }
    init(repository: TeamsRepository, transport: any TeamsHTTPTransport, vault: any TeamsTokenStoring, automaticSync: Bool, pollingClock: any TeamsRetryClock = TeamsSystemRetryClock(), syntheticMode: Bool = false, syntheticFileRoot: URL? = nil, fileDownloader: any TeamsFileDownloading = TeamsHTTPSFileDownloader()) {
        self.repository = repository; self.transport = transport; self.vault = vault; self.automaticSync = automaticSync
        self.pollingClock = pollingClock; self.syntheticMode = syntheticMode; self.syntheticFileRoot = syntheticFileRoot; self.fileDownloader = fileDownloader
        oauth = TeamsOAuthClient(transport: transport)
    }
    func check() throws { try Task.checkCancellation(); guard !stopped else { throw CancellationError() } }
    func check(accountID: UUID, generation: UUID) throws {
        try check(); guard generations[accountID] == generation else { throw CancellationError() }
    }
    private func checkGrant(accountID: UUID, id: UUID) throws {
        try checkStartingGrant(accountID: accountID, id: id)
        guard grants[accountID]?.id == id else { throw CancellationError() }
    }
    private func checkStartingGrant(accountID: UUID, id: UUID) throws {
        try check(); guard grantGenerations[accountID] == id else { throw CancellationError() }
    }
    public func load(configuration: ContactWorkspaceConfiguration) async throws -> [TeamsAccount] {
        try check()
        let openedConfiguration = syntheticMode ? try TeamsQAIsolation.normalizedDatabase(configuration) : configuration
        try await repository.open(configuration: openedConfiguration)
        #if DEBUG
        if syntheticMode { try await seedSynthetic() }
        #endif
        try check()
        self.configuration = openedConfiguration
        if projection == nil { projection = TeamsArchiveProjection(configuration: openedConfiguration, repository: repository, keyProvider: repository.keyProvider) }
        let accounts = try await repository.accounts()
        try check()
        return accounts
    }
    public func addAccount(name: String, configuration: TeamsOAuthConfiguration, readOnly: Bool) async throws -> TeamsAccount {
        try check(); try configuration.validate()
        let account = TeamsAccount(id: UUID(), name: name, clientID: configuration.clientID, authority: configuration.authority, verifiedPrincipal: nil, readOnly: readOnly)
        try await repository.saveAccount(account); try check(); return account
    }
    public func beginAuthorization(accountID: UUID, method: TeamsAuthorizationMethod, capabilities: Set<TeamsCapability>) async throws -> TeamsAuthorizationPresentation {
        try check()
        try await cancelAuthorization(accountID: accountID)
        try check()
        let id = UUID(), permit = TeamsAuthorizationPermit()
        grantGenerations[accountID] = id
        let account = try await repository.account(accountID)
        try checkStartingGrant(accountID: accountID, id: id)
        let configuration = TeamsOAuthConfiguration(clientID: account.clientID, authority: account.authority)
        presentations[accountID] = .pending
        if method == .browserPKCE {
            let listener = TeamsLoopbackAuthorization()
            let url = try await listener.start()
            do { try checkStartingGrant(accountID: accountID, id: id) }
            catch { await listener.cancel(); throw error }
            let challenge = try await oauth.beginPKCE(configuration: configuration, capabilities: capabilities, callbackURL: url)
            do { try checkStartingGrant(accountID: accountID, id: id) }
            catch { await listener.cancel(); await oauth.cancelPKCE(id: challenge.id); throw error }
            try await listener.expect(state: challenge.state)
            do { try checkStartingGrant(accountID: accountID, id: id) }
            catch { await listener.cancel(); await oauth.cancelPKCE(id: challenge.id); throw error }
            grants[accountID] = Grant(id: id, kind: .browser(challenge, listener), permit: permit, task: nil)
            presentations[accountID] = .browser(challenge.authorizationURL)
            grants[accountID]?.task = Task { [weak self] in
                do {
                    let callback = try await listener.callback()
                    try await self?.completeAuthorization(accountID: accountID, callback: callback)
                } catch is CancellationError {} catch { await self?.grantFailed(accountID: accountID, id: id, error: error) }
            }
        } else {
            let challenge = try await oauth.beginDevice(configuration: configuration, capabilities: capabilities)
            do { try checkStartingGrant(accountID: accountID, id: id) }
            catch { await oauth.cancelDevice(id: challenge.id); throw error }
            grants[accountID] = Grant(id: id, kind: .device(challenge), permit: permit, task: nil)
            presentations[accountID] = .device(userCode: challenge.userCode, verificationURL: challenge.verificationURL,
                expiresAt: challenge.expiresAt, nextPollAt: Date().addingTimeInterval(challenge.interval))
            grants[accountID]?.task = Task { [weak self] in
                var interval = challenge.interval
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(interval))
                        guard let next = try await self?.pollAuthorization(accountID: accountID, id: id) else { return }
                        interval = next
                    } catch is CancellationError { return } catch { await self?.grantFailed(accountID: accountID, id: id, error: error); return }
                }
            }
        }
        return presentations[accountID] ?? .pending
    }
    func completeAuthorization(accountID: UUID, callback: Data) async throws {
        guard let grant = grants[accountID], case let .browser(challenge, listener) = grant.kind else { throw CancellationError() }
        try checkGrant(accountID: accountID, id: grant.id)
        await listener.cancel() // Also releases a synthetic/manual callback's pending listener.
        try checkGrant(accountID: accountID, id: grant.id)
        let lease = try await repository.acquireLease(kind: .refresh, accountID: accountID, operationID: grant.id)
        do {
            try checkGrant(accountID: accountID, id: grant.id)
            let bundle = try await oauth.exchange(challenge: challenge, callback: callback)
            try checkGrant(accountID: accountID, id: grant.id)
            try await finishAuthorization(accountID: accountID, grant: grant, bundle: bundle)
            try await repository.releaseLease(lease)
        } catch { try? await repository.releaseLease(lease); throw error }
        try await connect(accountID: accountID)
    }
    private func pollAuthorization(accountID: UUID, id: UUID) async throws -> TimeInterval? {
        try checkGrant(accountID: accountID, id: id)
        guard let grant = grants[accountID], case let .device(challenge) = grant.kind else { throw CancellationError() }
        let lease = try await repository.acquireLease(kind: .refresh, accountID: accountID, operationID: grant.id)
        do {
            let result = try await oauth.pollDevice(challenge: challenge, now: Date())
            try checkGrant(accountID: accountID, id: id)
            switch result {
            case let .pending(date, interval):
                presentations[accountID] = .device(userCode: challenge.userCode, verificationURL: challenge.verificationURL, expiresAt: challenge.expiresAt, nextPollAt: date)
                try await repository.releaseLease(lease)
                return interval
            case let .authorized(bundle):
                try await finishAuthorization(accountID: accountID, grant: grant, bundle: bundle)
                try await repository.releaseLease(lease)
            }
        } catch { try? await repository.releaseLease(lease); throw error }
        try await connect(accountID: accountID)
        return nil
    }
    private func finishAuthorization(accountID: UUID, grant: Grant, bundle: TeamsTokenBundle) async throws {
        let account = try await repository.account(accountID)
        try checkGrant(accountID: accountID, id: grant.id)
        let verified = try await oauth.verifyIdentity(bundle: bundle, configuration: TeamsOAuthConfiguration(clientID: account.clientID, authority: account.authority), expected: account.verifiedPrincipal)
        try checkGrant(accountID: accountID, id: grant.id)
        try await repository.bindPrincipal(accountID: accountID, principal: verified.principal, permit: grant.permit)
        try checkGrant(accountID: accountID, id: grant.id)
        try await vault.save(verified.bundle, accountID: accountID, permit: grant.permit)
        try checkGrant(accountID: accountID, id: grant.id)
        grants[accountID] = nil; presentations[accountID] = .ready
    }
    private func grantFailed(accountID: UUID, id: UUID, error: any Error) async {
        guard !stopped, let grant = grants[accountID], grant.id == id else { return }
        grant.permit.cancel()
        if case let .browser(challenge, listener) = grant.kind { await listener.cancel(); await oauth.cancelPKCE(id: challenge.id) }
        if case let .device(challenge) = grant.kind { await oauth.cancelDevice(id: challenge.id) }
        guard grants[accountID]?.id == id, !stopped else { return }
        grants[accountID] = nil; presentations[accountID] = .failed(error as? TeamsFailure ?? .transport)
    }
    public func authorizationStatus(accountID: UUID) throws -> TeamsAuthorizationPresentation { try check(); return presentations[accountID] ?? .cancelled }
    public func cancelAuthorization(accountID: UUID) async throws {
        try check()
        grantGenerations[accountID] = UUID()
        presentations[accountID] = .cancelled
        guard let grant = grants.removeValue(forKey: accountID) else { return }
        grant.permit.cancel(); grant.task?.cancel(); presentations[accountID] = .cancelled
        switch grant.kind {
        case let .browser(challenge, listener): await listener.cancel(); await oauth.cancelPKCE(id: challenge.id)
        case let .device(challenge): await oauth.cancelDevice(id: challenge.id)
        }
    }
    public func connect(accountID: UUID) async throws {
        try check()
        let generation = UUID(); generations[accountID] = generation; states[accountID] = .connecting
        jobs.removeValue(forKey: accountID)?.cancel()
        let old = sessions.removeValue(forKey: accountID)
        let pending = connectingSessions.removeValue(forKey: accountID)
        await pending?.close()
        await old?.close()
        try check(accountID: accountID, generation: generation)
        let account = try await repository.account(accountID)
        try check(accountID: accountID, generation: generation)
        guard let principal = account.verifiedPrincipal else { states[accountID] = .signInRequired; throw TeamsFailure.signInRequired }
        let context = TeamsAccountContext(accountID: accountID, principal: principal)
        let configuration = TeamsOAuthConfiguration(clientID: account.clientID, authority: principal.tenantID)
        let session = TeamsSession(context: context, configuration: configuration, repository: repository, vault: vault, transport: transport)
        connectingSessions[accountID] = session
        do {
            _ = try await session.token()
            try check(accountID: accountID, generation: generation)
            guard let bundle = try await vault.load(accountID: accountID) else { throw TeamsFailure.signInRequired }
            try check(accountID: accountID, generation: generation)
            _ = try await oauth.verifyIdentity(bundle: bundle, configuration: configuration, expected: principal)
            try check(accountID: accountID, generation: generation)
            connectingSessions[accountID] = nil
            sessions[accountID] = session; states[accountID] = syntheticMode ? .synthetic : .connected
            let sync = TeamsSynchronization(context: context, graph: session.graph, repository: repository)
            synchronizers[accountID] = sync
            if automaticSync {
                jobs[accountID] = Task { [weak self] in await self?.poll(accountID: accountID, generation: generation) }
            }
        } catch {
            await session.close()
            if generations[accountID] == generation { connectingSessions[accountID] = nil }
            try check(accountID: accountID, generation: generation)
            states[accountID] = (error as? TeamsFailure) == .signInRequired ? .signInRequired : .failed(error as? TeamsFailure ?? .transport)
            throw error
        }
    }
    public func synchronize(accountID: UUID) async throws {
        try check()
        guard let session = sessions[accountID], let sync = synchronizers[accountID], let generation = generations[accountID] else { throw TeamsFailure.signInRequired }
        let token = try await session.token(); try check(accountID: accountID, generation: generation)
        let capabilities = try await session.capabilities(); try check(accountID: accountID, generation: generation)
        try await sync.synchronizeCatalogue(token: token, capabilities: capabilities)
        try check(accountID: accountID, generation: generation)
        try await projection?.drain()
        try check(accountID: accountID, generation: generation)
        if let fileService {
            try beginMutation(); defer { finishMutation() }
            let authorize: @Sendable () async throws -> Void = { try await self.check(accountID: accountID, generation: generation) }
            let guarded = TeamsAuthorizedTransport(base: transport, authorize: authorize)
            try await fileService.capturePending(accountID: accountID, graph: TeamsGraphFiles(context: session.context, transport: guarded), token: token, capabilities: capabilities, downloader: fileDownloader, authorize: authorize)
        }
        try check(accountID: accountID, generation: generation)
    }
    private func poll(accountID: UUID, generation: UUID) async {
        while !Task.isCancelled, !stopped, generations[accountID] == generation {
            var delay: TimeInterval = 15
            do { try await synchronize(accountID: accountID) }
            catch is CancellationError { return }
            catch let failure as TeamsFailure {
                guard !stopped, generations[accountID] == generation else { return }
                if case let .throttled(retryAfter) = failure { delay = max(delay, retryAfter) }
                if failure == .unauthorized || failure == .signInRequired { states[accountID] = .signInRequired; return }
            } catch { guard !stopped, generations[accountID] == generation else { return } }
            do {
                // Never convert an unbounded provider Double to Duration (which can overflow).
                // Cancellable chunks preserve the entire cooldown instead of retrying after a cap.
                var remaining = delay
                guard remaining.isFinite else { return }
                while remaining > 0 {
                    try check(accountID: accountID, generation: generation)
                    let chunk = min(remaining, 3600)
                    try await pollingClock.sleep(seconds: chunk)
                    remaining -= chunk
                }
            } catch { return }
        }
    }
    public func disconnect(accountID: UUID) async throws {
        try check()
        generations[accountID] = UUID(); states[accountID] = .disconnected
        jobs.removeValue(forKey: accountID)?.cancel()
        let session = sessions.removeValue(forKey: accountID), sync = synchronizers.removeValue(forKey: accountID)
        let pending = connectingSessions.removeValue(forKey: accountID)
        await sync?.close(); await session?.close(); await pending?.close()
        try await cancelAuthorization(accountID: accountID)
    }
    public func snapshot(accountID: UUID) async throws -> TeamsWorkspaceSnapshot {
        try check()
        let generation = generations[accountID]
        let account = try await repository.account(accountID); try checkRead(accountID: accountID, generation: generation)
        let chats = try await repository.conversations(accountID: accountID); try checkRead(accountID: accountID, generation: generation)
        let teams = try await repository.teams(accountID: accountID); try checkRead(accountID: accountID, generation: generation)
        let channels = try await repository.channels(accountID: accountID); try checkRead(accountID: accountID, generation: generation)
        let progress = await synchronizers[accountID]?.progress() ?? TeamsSyncProgress(); try checkRead(accountID: accountID, generation: generation)
        let capabilities = try await sessions[accountID]?.capabilities() ?? []; try checkRead(accountID: accountID, generation: generation)
        return TeamsWorkspaceSnapshot(accountID: accountID, principal: account.verifiedPrincipal, state: states[accountID] ?? .disconnected,
            chats: chats, teams: teams, channels: channels, progress: progress, capabilities: capabilities)
    }
    func checkRead(accountID: UUID, generation: UUID?) throws {
        try check(); guard generations[accountID] == generation else { throw CancellationError() }
    }
    public func messages(scope: TeamsScope, before: TeamsRetainedCursor?) async throws -> TeamsRetainedPage {
        try check(); let generation = generations[scope.accountID]
        let value = try await repository.messages(scope: scope, before: before); try checkRead(accountID: scope.accountID, generation: generation); return value
    }
    public func search(scope: TeamsScope, query: String, before: TeamsRetainedCursor?) async throws -> TeamsRetainedPage {
        try check(); let generation = generations[scope.accountID]
        let value = try await repository.search(scope: scope, query: query, before: before); try checkRead(accountID: scope.accountID, generation: generation); return value
    }
    public func archivePage(scope: TeamsScope, before: Int64?) async throws -> [MessageArchiveRecord] {
        try check(); let generation = generations[scope.accountID]
        _ = try await repository.validate(scope); try checkRead(accountID: scope.accountID, generation: generation)
        guard let projection else { throw TeamsFailure.storage }
        let value = try await projection.page(scope: scope, before: before); try checkRead(accountID: scope.accountID, generation: generation); return value
    }
    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        for grant in grants.values { grant.permit.cancel(); grant.task?.cancel() }
        let pending = Array(grants.values); grants.removeAll()
        for job in jobs.values { job.cancel() }; jobs.removeAll()
        let old = Array(sessions.values) + Array(connectingSessions.values), syncing = Array(synchronizers.values)
        sessions.removeAll(); synchronizers.removeAll()
        connectingSessions.removeAll()
        for grant in pending {
            switch grant.kind {
            case let .browser(challenge, listener): await listener.cancel(); await oauth.cancelPKCE(id: challenge.id)
            case let .device(challenge): await oauth.cancelDevice(id: challenge.id)
            }
        }
        for sync in syncing { await sync.close() }
        for session in old { await session.close() }
        if admittedMutations > 0 { await withCheckedContinuation { mutationDrain.append($0) } }
        fileService = nil; projection = nil
        await repository.close()
    }
}

extension TeamsWorker {
    func sendingSession(scope: TeamsScope) async throws -> (TeamsSession, UUID) {
        try check()
        guard let session = sessions[scope.accountID], let generation = generations[scope.accountID] else { throw TeamsFailure.signInRequired }
        let account = try await repository.validate(scope)
        try check(accountID: scope.accountID, generation: generation)
        guard !account.readOnly else { throw TeamsFailure.forbidden }
        let capabilities = try await session.capabilities()
        try check(accountID: scope.accountID, generation: generation)
        let required: TeamsCapability
        if case .chat = scope.resource { required = .sendChat } else { required = .sendChannel }
        guard capabilities.contains(required) else { throw TeamsFailure.forbidden }
        return (session, generation)
    }
    public func send(scope: TeamsScope, content: TeamsDraft) async throws -> TeamsOutgoing {
        let (_, generation) = try await sendingSession(scope: scope)
        try check(accountID: scope.accountID, generation: generation)
        let prepared = try await repository.prepareOutgoing(scope: scope, content: content)
        try check(accountID: scope.accountID, generation: generation)
        return try await resumeOutgoing(accountID: scope.accountID, id: prepared.id)
    }
    public func resumeOutgoing(accountID: UUID, id: UUID) async throws -> TeamsOutgoing {
        try check()
        let prepared = try await repository.outgoing(id: id, accountID: accountID)
        guard prepared.state == .prepared else { throw prepared.state == .unknown || prepared.state == .dispatching ? TeamsFailure.uncertainSubmission : .invalidResource }
        let (session, generation) = try await sendingSession(scope: prepared.scope)
        let token = try await session.token()
        try check(accountID: accountID, generation: generation)
        try beginMutation()
        defer { finishMutation() }
        let claimed = try await repository.claimOutgoing(id: id, accountID: accountID)
        if claimed.fileSubmission != nil {
            guard let fileService else {
                guard let attempt = claimed.attemptID else { throw TeamsFailure.storage }
                return try await repository.settleOutgoing(id: id, accountID: accountID, attemptID: attempt, outcome: .unknown)
            }
            let authorize: @Sendable () async throws -> Void = { try await self.check(accountID: accountID, generation: generation) }
            let guarded = TeamsAuthorizedTransport(base: transport, authorize: authorize)
            let pipeline = TeamsFileSubmission(repository: repository, files: fileService, graph: TeamsGraphFiles(context: session.context, transport: guarded))
            let result = try await pipeline.dispatch(claimed, token: token, capabilities: session.capabilities(), authorize: authorize)
            try check(accountID: accountID, generation: generation); return result
        }
        guard let attempt = claimed.attemptID else { throw TeamsFailure.storage }
        let outcome: TeamsAttemptOutcome
        do {
            try check(accountID: accountID, generation: generation)
            let message = try await session.graph.postMessage(scope: claimed.scope, content: claimed.content, token: token)
            outcome = .accepted(message)
        } catch let failure as TeamsFailure {
            if case let .server(status) = failure, (400..<500).contains(status), status != 408 { outcome = .notSent(failure) }
            else { outcome = .unknown }
        } catch { outcome = .unknown }
        // A received receipt must settle its admitted immutable attempt even if UI selection/disconnect changed.
        let settled = try await repository.settleOutgoing(id: id, accountID: accountID, attemptID: attempt, outcome: outcome)
        try check(accountID: accountID, generation: generation)
        return settled
    }
    public func copyOutgoing(accountID: UUID, id: UUID) async throws -> TeamsOutgoing {
        try check()
        let value = try await repository.outgoing(id: id, accountID: accountID)
        guard value.state == .notSent, value.fileSubmission == nil else { throw TeamsFailure.uncertainSubmission }
        _ = try await sendingSession(scope: value.scope)
        return try await repository.prepareOutgoing(scope: value.scope, content: value.content)
    }
    public func resolveOutgoing(accountID: UUID, id: UUID, sent: Bool) async throws -> TeamsOutgoing {
        try check(); let value = try await repository.resolveOutgoing(id: id, accountID: accountID, sent: sent); try check(); return value
    }
    public func outgoingPage(accountID: UUID, before: TeamsOutgoingCursor?) async throws -> TeamsOutgoingPage {
        try check(); let generation = generations[accountID]
        let page = try await repository.outgoingPage(accountID: accountID, before: before); try checkRead(accountID: accountID, generation: generation); return page
    }
}
