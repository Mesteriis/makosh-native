import Foundation
import MakoshCore
import MakoshJira

/// Everything the section shows at once; value copies cross to the main actor.
public struct TasksSnapshot: Sendable {
    public var tasks: [Task] = []
    public var observations: [UUID: TaskProviderObservation] = [:]
    public var attempts: [UUID: [TaskJiraAttempt]] = [:]
    public var entries: [UUID: [TaskTimeEntry]] = [:]
    public var timer: TaskTimer?
    public var connections: [JiraConnection] = []
    public var projectStatuses: [UUID: [String: [JiraStatus]]] = [:]
    public var priorities: [UUID: [JiraPriority]] = [:]
    public var preferences = TaskPreferences()
    public var journalFailure: String?
    public init() {}
}

/// The section's service: owns the store, journal, time service, registry
/// and one mirror per connection; polls on the connections' intervals.
public actor TasksService {
    public typealias AdapterFactory = @Sendable (JiraConnection, String) -> any JiraAdapter
    public let store: TaskStore
    public let vault: JiraTokenVault
    public let registry: JiraConnectionRegistry
    public let journal: TaskJiraAttemptJournal
    public let time: TaskTimeService
    private let adapterFactory: AdapterFactory
    private let now: @Sendable () -> Date
    private var mirrors: [UUID: JiraMirror] = [:]
    private var adapters: [UUID: any JiraAdapter] = [:]
    private var projectStatuses: [UUID: [String: [JiraStatus]]] = [:]
    private var priorities: [UUID: [JiraPriority]] = [:]
    private var polling: _Concurrency.Task<Void, Never>?
    private var opened = false
    /// Grows every time the mirror applied outside changes; the model clears undo when it moves.
    public private(set) var outsideChanges = 0

    public init(
        store: TaskStore, vault: JiraTokenVault, now: @escaping @Sendable () -> Date = Date.init,
        adapterFactory: @escaping AdapterFactory = { JiraCloudAdapter(credential: $0.credential(token: $1)) }
    ) {
        self.store = store
        self.vault = vault
        self.now = now
        self.adapterFactory = adapterFactory
        registry = JiraConnectionRegistry(store: store, vault: vault)
        let journal = TaskJiraAttemptJournal(store: store, now: now) { _ in nil }
        self.journal = journal
        time = TaskTimeService(store: store, journal: journal, now: now)
    }

    /// Opens the store, settles in-flight attempts and builds the mirrors.
    public func open() async throws {
        guard !opened else { return }
        try await store.open()
        opened = true
        await journal.attach { [weak self] id in await self?.adapter(for: id) }
        await journal.resume()
        for connection in try await store.connections() { try await attach(connection) }
    }

    public func close() async {
        stopPolling()
        await store.close()
        opened = false
    }

    public func snapshot() async -> TasksSnapshot {
        var value = TasksSnapshot()
        do {
            value.tasks = try await store.tasks()
            for task in value.tasks where task.source != nil {
                value.observations[task.id] = try await store.latestObservation(taskID: task.id)
                let attempts = try await store.attempts(taskID: task.id)
                if !attempts.isEmpty { value.attempts[task.id] = attempts }
            }
            for task in value.tasks {
                let entries = try await store.entries(taskID: task.id)
                if !entries.isEmpty { value.entries[task.id] = entries }
            }
            value.timer = try await store.timer()
            value.connections = try await store.connections()
            value.preferences = try await store.preferences()
        } catch {
            value.journalFailure = "Хранилище задач недоступно."
        }
        value.projectStatuses = projectStatuses
        value.priorities = priorities
        if let failure = await journal.lastFailure { value.journalFailure = failure }
        return value
    }

    // MARK: Connections

    public func adapter(for connectionID: UUID) async -> (any JiraAdapter)? {
        if let adapter = adapters[connectionID] { return adapter }
        guard let connection = try? await store.connections().first(where: { $0.id == connectionID }),
            let token = try? await vault.load(connectionID: connectionID)
        else { return nil }
        let adapter = adapterFactory(connection, token)
        adapters[connectionID] = adapter
        return adapter
    }

    /// Checks the credentials against `myself` without saving anything.
    public func verify(_ connection: JiraConnection, token: String) async throws -> JiraUser {
        try await adapterFactory(try connection.validated(), token).currentUser()
    }

    public func save(_ connection: JiraConnection, token: String?) async throws {
        try await registry.save(connection, token: token)
        adapters[connection.id] = nil
        mirrors[connection.id] = nil
        try await attach(connection)
    }

    public func remove(connectionID: UUID) async throws {
        try await registry.remove(connectionID)
        adapters[connectionID] = nil
        mirrors[connectionID] = nil
        projectStatuses[connectionID] = nil
        priorities[connectionID] = nil
    }

    private func attach(_ connection: JiraConnection) async throws {
        guard let adapter = await adapter(for: connection.id) else { return }
        var value = connection
        if value.accountID == nil, let me = try? await adapter.currentUser() {
            value.accountID = me.accountID
            try await store.saveConnection(value)
        }
        guard let accountID = value.accountID else { return }
        mirrors[connection.id] = JiraMirror(
            store: store, connectionID: connection.id, adapter: adapter, accountID: accountID, mentions: value.mentions,
            lastSuccessfulSync: value.lastSyncAt, now: now)
    }

    // MARK: Sync

    /// Every mirror once; `full` demotes issues that left the selection.
    @discardableResult public func syncAll(full: Bool) async -> [UUID: JiraMirrorResult] {
        var results: [UUID: JiraMirrorResult] = [:]
        for (id, mirror) in mirrors { results[id] = await sync(mirror: mirror, connectionID: id, full: full) }
        return results
    }

    @discardableResult public func syncNow(connectionID: UUID, full: Bool = true) async -> JiraMirrorResult? {
        guard let mirror = mirrors[connectionID] else { return nil }
        return await sync(mirror: mirror, connectionID: connectionID, full: full)
    }

    private func sync(mirror: JiraMirror, connectionID: UUID, full: Bool) async -> JiraMirrorResult {
        let result = await mirror.sync(full: full)
        if result.applied > 0 || result.left > 0 { outsideChanges += 1 }
        if var connection = try? await store.connections().first(where: { $0.id == connectionID }) {
            connection.lastSyncAt = await mirror.lastSync
            connection.lastFailure = result.failure
            connection.mentionsUnavailable = result.mentionsUnavailable
            try? await store.saveConnection(connection)
        }
        await loadReference(connectionID: connectionID)
        return result
    }

    /// Statuses of every project seen and the priority list, for the board and the card.
    private func loadReference(connectionID: UUID) async {
        guard let adapter = adapters[connectionID], let sources = try? await store.sources(connectionID: connectionID) else { return }
        var projects: Set<String> = []
        for (taskID, _) in sources {
            if let observation = try? await store.latestObservation(taskID: taskID) { projects.insert(observation.issue.projectKey) }
        }
        var statuses = projectStatuses[connectionID] ?? [:]
        for project in projects where statuses[project] == nil {
            if let value = try? await adapter.projectStatuses(projectKey: project) { statuses[project] = value }
        }
        projectStatuses[connectionID] = statuses
        if priorities[connectionID] == nil, let value = try? await adapter.priorities() { priorities[connectionID] = value }
    }

    /// Rereads one issue with its transitions, comments and worklogs; worklog changes flow to the entries.
    public func refreshIssue(taskID: UUID) async throws -> TaskProviderObservation? {
        guard let task = try await store.task(id: taskID), let source = task.source,
            let connectionID = UUID(uuidString: source.identity.accountID),
            let mirror = mirrors[connectionID]
        else { return nil }
        let observation = try await mirror.refresh(issueID: source.identity.externalID)
        try await time.applyWorklogs(observation.myWorklogs, taskID: taskID)
        outsideChanges += 1
        return observation
    }

    public func startPolling() {
        guard polling == nil else { return }
        polling = _Concurrency.Task { [weak self] in
            var counter = 0
            while !_Concurrency.Task.isCancelled {
                do { try await _Concurrency.Task.sleep(for: .seconds(30)) } catch { return }
                guard !_Concurrency.Task.isCancelled, let self else { return }
                counter += 1
                await self.pollDue(tick: counter)
            }
        }
    }

    public func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    private func pollDue(tick: Int) async {
        guard let connections = try? await store.connections() else { return }
        for connection in connections {
            guard let mirror = mirrors[connection.id] else { continue }
            let last = await mirror.lastSync ?? .distantPast
            let due = now().timeIntervalSince(last) >= connection.pollInterval
            // A full pass once a day keeps departures honest; the rest are incremental.
            let full = now().timeIntervalSince(last) >= 86_400 || last == .distantPast
            if due { _ = await sync(mirror: mirror, connectionID: connection.id, full: full) }
        }
    }
}

extension TaskJiraAttemptJournal {
    /// Lets the service hand over adapter lookup after both exist.
    public func attach(_ lookup: @escaping AdapterLookup) { replaceAdapterLookup(lookup) }
}
