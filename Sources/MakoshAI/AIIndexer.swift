import Foundation
import MakoshCore

/// Which sources and contacts the user made available, read fresh before
/// indexing and again after every provider response.
public struct AIAccessSnapshot: Sendable, Equatable {
    public let enabledScopes: Set<AIAccessScope>
    public let contactAccess: [ServiceIdentity: AIContactAccess]
    public init(enabledScopes: Set<AIAccessScope>, contactAccess: [ServiceIdentity: AIContactAccess]) {
        self.enabledScopes = enabledScopes
        self.contactAccess = contactAccess
    }
    /// The chat or mailbox must be enabled; an incoming message is closed
    /// when its author's contact is forbidden. Own messages are not.
    public func admits(_ item: AIIndexItem) -> Bool {
        guard enabledScopes.contains(item.scope) else { return false }
        guard !item.isOutgoing, let author = item.author else { return true }
        return contactAccess[author] != .forbidden
    }
    func admits(_ chunk: AIChunk) -> Bool {
        enabledScopes.contains(chunk.scope) && !chunk.authors.contains { contactAccess[$0] == .forbidden }
    }
    var forbidden: Set<ServiceIdentity> { Set(contactAccess.filter { $0.value == .forbidden }.keys) }
}

public protocol AIAccessProvider: Sendable {
    func snapshot() async throws -> AIAccessSnapshot
    func setScope(_ scope: AIAccessScope, enabled: Bool) async throws
}

public struct AIIndexStatus: Sendable, Equatable {
    public var indexed = 0
    public var pending = 0
    public var paused = false
    public var failure: AIFailure?
}

struct AIIndexState: Codable {
    struct Target: Codable, Equatable {
        let connectionID: UUID
        let model: String
        var generation: Int64?
        func same(_ other: Target?) -> Bool { other?.connectionID == connectionID && other?.model == model }
    }
    struct Backfill: Codable {
        let scope: AIAccessScope
        var cursors: [String: Int64] = [:]
        var done: Set<String> = []
    }
    var cursors: [String: Int64] = [:]
    /// Sequences already read below each cursor, so a late commit inside the
    /// re-read window is indexed once.
    var recent: [String: [Int64]] = [:]
    var backfill: [Backfill] = []
    var enabled: [AIAccessScope] = []
    var forbidden: [ServiceIdentity] = []
    var building: Target?
    var ready: Target?
}

/// Follows every source with its own cursor, back-fills newly enabled
/// scopes, and keeps the vector index in step with the access flags.
/// Nothing reaches the provider without passing the current snapshot, and
/// nothing is stored that stopped passing while the request was in flight.
public actor AIIndexer {
    static let overlap: Int64 = 1000
    static let pageSize = 200
    static let livePages = 10
    static let backfillPages = 5
    static let batchSize = 64
    private let worker: AIWorker
    private let vectors: AIVectorStore
    private let sources: [any AIIndexSource]
    private let access: any AIAccessProvider
    private let pace: Duration
    private var current = AIIndexStatus()
    private var loop: Task<Void, Never>?
    private var running = false

    public init(
        worker: AIWorker, vectors: AIVectorStore, sources: [any AIIndexSource], access: any AIAccessProvider, pace: Duration = .milliseconds(500)
    ) {
        self.worker = worker
        self.vectors = vectors
        self.sources = sources
        self.access = access
        self.pace = pace
    }

    public func status() -> AIIndexStatus { current }

    public func pause(_ paused: Bool) {
        current.paused = paused
        if !paused, current.failure == .unauthorized { current.failure = nil }
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                _ = try? await self?.runOnce()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    public func accessChanged() {
        Task { _ = try? await self.runOnce() }
    }

    public func close() async {
        loop?.cancel()
        loop = nil
    }

    @discardableResult
    public func runOnce() async throws -> AIIndexStatus {
        guard !current.paused, !running else { return current }
        running = true
        defer { running = false }
        do {
            try await cycle()
            current.failure = nil
        } catch let failure as AIFailure {
            current.failure = failure
            if failure == .unauthorized { current.paused = true }
        } catch is CancellationError {
            current.failure = .cancelled
        }
        return current
    }

    private func cycle() async throws {
        let role = try await worker.embeddingRole()
        guard try await vectors.available() else { throw AIFailure.vectorUnavailable }
        let snapshot = try await access.snapshot()
        var state = try await worker.indexState() ?? AIIndexState()

        // Access changes: purge what closed, back-fill what opened.
        let previous = Set(state.enabled), enabled = snapshot.enabledScopes
        for scope in previous.subtracting(enabled) {
            try await vectors.delete(scope: scope)
            state.backfill.removeAll { $0.scope == scope }
        }
        let forbidden = snapshot.forbidden, wasForbidden = Set(state.forbidden)
        for identity in forbidden.subtracting(wasForbidden) { try await vectors.delete(author: identity) }
        let changed = forbidden.symmetricDifference(wasForbidden)
        var refill = enabled.subtracting(previous).union(enabled.filter { scope in changed.contains { Self.belongs($0, to: scope) } })
        let target = AIIndexState.Target(connectionID: role.connectionID, model: role.model, generation: nil)
        if !target.same(state.building) && !target.same(state.ready) {
            state.building = target
            refill = enabled
        }
        for scope in refill {
            state.backfill.removeAll { $0.scope == scope }
            state.backfill.append(.init(scope: scope))
        }
        state.enabled = enabled.sorted { "\($0)" < "\($1)" }
        state.forbidden = forbidden.sorted { $0.id < $1.id }

        // New journal entries, re-reading a window below each cursor.
        var items: [AIIndexItem] = []
        var edited = Set<AIAccessScope>()
        for source in sources {
            let cursor = state.cursors[source.name, default: 0]
            var seen = Set(state.recent[source.name, default: []])
            var after = max(0, cursor - Self.overlap), highest = cursor
            for _ in 0..<Self.livePages {
                let page = try await source.items(after: after, limit: Self.pageSize)
                for item in page where seen.insert(item.sequence).inserted {
                    if item.removed {
                        try await vectors.delete(message: item.identity)
                    } else if try await vectors.hasMessage(item.identity) {
                        // An edit: drop chunks with the old text and rebuild the conversation from its current state.
                        try await vectors.delete(message: item.identity)
                        edited.insert(item.scope)
                    } else {
                        items.append(item)
                    }
                }
                highest = max(highest, page.last?.sequence ?? highest)
                guard page.count == Self.pageSize, let last = page.last?.sequence else { break }
                after = last
            }
            state.cursors[source.name] = highest
            state.recent[source.name] = seen.filter { $0 > highest - Self.overlap }.sorted()
        }
        for scope in edited.intersection(enabled) where !state.backfill.contains(where: { $0.scope == scope }) {
            state.backfill.append(.init(scope: scope))
        }
        for index in state.backfill.indices {
            for source in sources where !state.backfill[index].done.contains(source.name) {
                var after = state.backfill[index].cursors[source.name, default: 0]
                var finished = false
                for _ in 0..<Self.backfillPages {
                    let page = try await source.items(in: state.backfill[index].scope, after: after, limit: Self.pageSize)
                    items += page.filter { !$0.removed }
                    after = page.last?.sequence ?? after
                    if page.count < Self.pageSize {
                        finished = true
                        break
                    }
                }
                state.backfill[index].cursors[source.name] = after
                if finished { state.backfill[index].done.insert(source.name) }
            }
        }
        state.backfill.removeAll { backfill in sources.allSatisfy { backfill.done.contains($0.name) } }

        // Embed only admitted chunks that are not stored yet.
        var destination = state.building ?? state.ready ?? target
        let admitted = items.filter { snapshot.admits($0) }
        if !admitted.isEmpty, destination.generation == nil {
            let probe = try await worker.embed(["makosh dimension probe"])
            let generation = try await vectors.generation(
                connectionID: probe.connectionID, model: probe.model, dimensions: probe.vectors.first?.count ?? 0)
            destination.generation = generation.id
        }
        if let generation = destination.generation {
            let chunks = AIChunker.chunks(admitted, generation: generation) { snapshot.admits($0) }
            let stored = try await vectors.contains(chunks.map(\.id), generation: generation)
            let missing = chunks.filter { !stored.contains($0.id) }
            for start in stride(from: 0, to: missing.count, by: Self.batchSize) {
                let batch = Array(missing[start..<min(start + Self.batchSize, missing.count)])
                let embedded = try await worker.embed(batch.map(\.text))
                guard embedded.connectionID == destination.connectionID, embedded.model == destination.model else { throw AIFailure.cancelled }
                let fresh = try await access.snapshot()
                let kept = zip(batch, embedded.vectors).filter { fresh.admits($0.0) }
                try await vectors.insert(kept.map { ($0.0, $0.1) }, generation: generation)
                if pace > .zero { try await Task.sleep(for: pace) }
            }
        }
        if state.building != nil { state.building = destination } else if state.ready != nil { state.ready = destination }

        // A finished rebuild becomes the answering generation.
        if let building = state.building, let generation = building.generation, state.backfill.isEmpty {
            try await vectors.markReady(generation)
            state.ready = building
            state.building = nil
        }
        try await worker.saveIndexState(state)
        current.pending = state.backfill.count
        if let generation = state.ready?.generation {
            current.indexed = try await vectors.count(generation: generation)
        } else {
            current.indexed = 0
        }
    }

    private static func belongs(_ identity: ServiceIdentity, to scope: AIAccessScope) -> Bool {
        switch scope {
        case .conversation(let service, let accountID, _): identity.service == service && identity.accountID == accountID
        case .mailAccount(let accountID): identity.service == "mail" && identity.accountID == accountID
        }
    }
}
