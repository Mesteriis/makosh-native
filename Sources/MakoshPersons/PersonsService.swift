import Foundation
import MakoshCore
import MakoshGoogle

/// What one write pass did.
public struct PersonsPassReport: Equatable, Sendable {
    public var attempted = 0
    public var confirmed = 0
    public var rejected = 0
    public var unknown = 0
    /// Books that still had writes left when the per-book limit was reached.
    public var deferredBooks: [UUID] = []
    public init() {}
}

/// The Persons section's service: books, their adapters, the write runner and the
/// collection. Protocol, SQL and Keychain work run here, never on the main actor.
public actor PersonsService {
    public typealias AdapterFactory = @Sendable (PersonBook, PersonsCredentialVault) async throws -> any PersonBookAdapter

    public let persons: PersonStore
    public let store: PersonsStore
    let vault: PersonsCredentialVault
    let adapterFactory: AdapterFactory
    let google: GoogleOAuth?
    let grants: GoogleGrantVault
    let now: @Sendable () -> Date
    var adapters: [UUID: any PersonBookAdapter] = [:]
    var capabilities: [UUID: PersonBookCapabilities] = [:]
    /// The last full read of each book: what reconciliation adopts from.
    var lastRemote: [UUID: [RemoteCard]] = [:]
    var writeTask: Task<Void, Never>?
    var writeAgain = false
    var pollTask: Task<Void, Never>?
    /// Books whose ETags moved: they are read before the next write.
    var pendingRead = Set<UUID>()

    public init(
        persons: PersonStore, store: PersonsStore, vault: PersonsCredentialVault, adapterFactory: @escaping AdapterFactory,
        google: GoogleOAuth?, grants: GoogleGrantVault, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persons = persons
        self.store = store
        self.vault = vault
        self.adapterFactory = adapterFactory
        self.google = google
        self.grants = grants
        self.now = now
    }

    public func open() async throws {
        try await store.open()
    }

    public func close() async {
        stopPolling()
        writeTask?.cancel()
        writeTask = nil
        adapters = [:]
        capabilities = [:]
        await store.close()
    }

    // MARK: Adapters

    func adapter(for book: PersonBook) async throws -> any PersonBookAdapter {
        if let cached = adapters[book.id] { return cached }
        let adapter = try await adapterFactory(book, vault)
        adapters[book.id] = adapter
        capabilities[book.id] = await adapter.capabilities
        return adapter
    }

    func capabilities(for book: PersonBook) async -> PersonBookCapabilities? {
        if let known = capabilities[book.id] { return known }
        guard let adapter = try? await adapter(for: book) else { return nil }
        return await adapter.capabilities
    }

    /// Marks a book's connection state after a failure; a rename or a switch made meanwhile stays.
    func mark(_ bookID: UUID, failure: PersonsFailure) async {
        guard var book = try? await store.book(id: bookID), book.state != .disabled else { return }
        switch failure {
        case .signInRequired, .rejected(code: 401, _): book.state = .needsSignIn
        case .noAccess, .rejected(code: 403, _): book.state = .noAccess
        case .retryAfter(let seconds): book.pausedUntil = now().addingTimeInterval(TimeInterval(seconds))
        case .unreachable, .unknownOutcome: book.state = .unreachable
        default: break
        }
        book.lastError = failure
        try? await store.saveBook(book)
        if book.state == .needsSignIn || book.state == .noAccess { adapters[bookID] = nil }
    }

    /// Books Makosh writes into right now.
    func writableBooks() async throws -> [PersonBook] {
        try await store.books().filter {
            $0.kind.isBook && $0.acceptsAddressBook && $0.state == .connected && ($0.pausedUntil.map { $0 <= now() } ?? true)
        }
    }

    // MARK: Coalesced pass

    /// Schedules one write pass; a request during a pass makes it run once more afterwards.
    public func requestWritePass() {
        guard writeTask == nil else {
            writeAgain = true
            return
        }
        writeTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                await self.resetWriteAgain()
                _ = await self.writePass()
            } while await self.takeWriteAgain()
            await self.finishWriteTask()
        }
    }

    private func resetWriteAgain() { writeAgain = false }
    private func takeWriteAgain() -> Bool {
        defer { writeAgain = false }
        return writeAgain && !Task.isCancelled
    }
    private func finishWriteTask() { writeTask = nil }

    /// Waits for the scheduled passes to finish (tests).
    public func settled() async {
        while let task = writeTask { await task.value }
    }

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = (try? await self.store.preferences().pollIntervalSeconds) ?? 600
                try? await Task.sleep(for: .seconds(max(30, seconds)))
                guard !Task.isCancelled else { return }
                await self.readAll()
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reads every connected book that is due; filled in by the book-reading extension.
    public func readAll() async {
        for book in (try? await store.books()) ?? [] where book.kind.isBook && book.readBook && book.state == .connected {
            if let paused = book.pausedUntil, paused > now() { continue }
            _ = try? await readBook(id: book.id)
        }
    }
}
