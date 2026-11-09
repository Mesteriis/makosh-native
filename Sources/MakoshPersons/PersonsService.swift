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
    let http: PersonsHTTP
    let now: @Sendable () -> Date
    let collector: PersonCollector
    var adapters: [UUID: any PersonBookAdapter] = [:]
    var capabilities: [UUID: PersonBookCapabilities] = [:]
    /// The last full read of each book: what reconciliation adopts from.
    var lastRemote: [UUID: [RemoteCard]] = [:]
    /// Books whose whole card list this process has read: only there may a card be created without a second look.
    var authoritativeRemote = Set<UUID>()
    var writeTask: Task<Void, Never>?
    var writeAgain = false
    var pollTask: Task<Void, Never>?
    /// Books whose ETags moved: they are read before the next write.
    var pendingRead = Set<UUID>()

    public init(
        persons: PersonStore, store: PersonsStore, vault: PersonsCredentialVault, adapterFactory: @escaping AdapterFactory,
        google: GoogleOAuth?, grants: GoogleGrantVault, http: PersonsHTTP = PersonsHTTP(), now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persons = persons
        self.store = store
        self.vault = vault
        self.adapterFactory = adapterFactory
        self.google = google
        self.grants = grants
        self.http = http
        self.now = now
        collector = PersonCollector(persons: persons, store: store, now: now)
    }

    // MARK: Collection

    /// Channels hand their observations here: the collector applies them, merged persons'
    /// cards follow the survivor, and a write pass is scheduled.
    @discardableResult
    public func collect(
        _ observations: [PersonSourceObservation], spam: [MailEvidence] = [], addressBookSource: ImportSource? = nil
    )
        async throws -> CollectResult
    {
        let result = try await collector.collect(observations, spam: spam, addressBookSource: addressBookSource)
        for pair in result.merged { try await moveEntries(from: pair.removed, to: pair.survivor) }
        if !observations.isEmpty { requestWritePass() }
        return result
    }

    // MARK: Snapshot

    public func snapshot() async throws -> PersonsSnapshot {
        let books = try await store.books()
        var capabilityMap: [UUID: PersonBookCapabilities] = [:]
        for book in books where book.kind.isBook && book.state == .connected {
            if let capability = await capabilities(for: book) { capabilityMap[book.id] = capability }
        }
        return PersonsSnapshot(
            books: books, entries: try await store.allEntries(), openAttempts: try await store.attempts(open: true),
            blocked: AddressBookEngine.blockedReasons(persons: try persons.persons(), books: books, capabilities: capabilityMap),
            preferences: try await store.preferences(), googleAvailable: google != nil)
    }

    // MARK: Books

    /// Registers an account without a network book (a channel) or a synthetic book for QA.
    @discardableResult
    public func connectSynthetic(name: String, accountID: String, isAddressBookSource: Bool = false) async throws -> PersonBook {
        let book = PersonBook(kind: .synthetic, name: name, accountID: accountID, isAddressBookSource: isAddressBookSource)
        try await store.saveBook(book)
        return book
    }

    @discardableResult
    public func connectTelegram(accountID: String, name: String) async throws -> PersonBook {
        if let existing = try await store.books().first(where: { $0.kind == .telegram && $0.accountID == accountID }) { return existing }
        let book = PersonBook(kind: .telegram, name: name, accountID: accountID)
        try await store.saveBook(book)
        return book
    }

    /// A channel account (mail, WhatsApp, Teams) known to the section for its «collect conversations» switch.
    @discardableResult
    public func ensureChannelSource(kind: PersonBookKind, accountID: String, name: String) async throws -> PersonBook {
        if let existing = try await store.books().first(where: { $0.kind == kind && $0.accountID == accountID }) { return existing }
        let book = PersonBook(kind: kind, name: name, accountID: accountID)
        try await store.saveBook(book)
        return book
    }

    /// A CardDAV account: the server's first address book is the collection; the password lives
    /// in the Keychain only, and nothing is saved until discovery succeeds. The same login on the
    /// same server is one book, so connecting again rotates the password.
    @discardableResult
    public func connectCardDAV(name: String, server: URL, login: String, password: String) async throws -> PersonBook {
        let found = try await CardDAVAdapter.discover(server: server, login: login, password: password, http: http)
        guard let collection = found.first else { throw PersonsFailure.notFound }
        let accountID = login + "@" + (server.host ?? server.absoluteString)
        var book =
            try await store.books().first { $0.kind == .carddav && $0.accountID == accountID }
            ?? PersonBook(kind: .carddav, name: name, accountID: accountID)
        book.name = name.isEmpty ? login : name
        book.caldavServer = collection.url
        book.caldavLogin = login
        book.state = .connected
        book.lastError = nil
        book.pausedUntil = nil
        try await vault.savePassword(bookID: book.id, password)
        try await store.saveBook(book)
        adapters[book.id] = nil
        _ = try await readBook(id: book.id)
        return try await store.book(id: book.id) ?? book
    }

    /// A Google account with the contacts scope; the grant goes to the shared Google vault.
    @discardableResult
    public func connectGoogle(loginHint: String?) async throws -> PersonBook {
        guard let google else { throw PersonsFailure.signInRequired }
        let grant = try await PersonsFailure.mapGoogle { try await google.signIn(scopes: GoogleOAuth.contactsScopes, loginHint: loginHint) }
        guard grant.has(scope: GoogleOAuth.contactsScope) else { throw PersonsFailure.signInRequired }
        try await grants.saveGrant(grant)
        var book =
            try await store.books().first { $0.kind == .googleContacts && $0.googleSubject == grant.subject }
            ?? PersonBook(kind: .googleContacts, name: grant.email, accountID: grant.subject, googleSubject: grant.subject)
        book.state = .connected
        book.lastError = nil
        book.pausedUntil = nil
        try await store.saveBook(book)
        adapters[book.id] = nil
        _ = try await readBook(id: book.id)
        return try await store.book(id: book.id) ?? book
    }

    /// The macOS address book of this Mac; access is asked by the caller before this runs.
    @discardableResult
    public func connectMacContacts() async throws -> PersonBook {
        guard MacContactsAdapter.authorizationStatus == .authorized else { throw PersonsFailure.noAccess }
        var book =
            try await store.books().first { $0.kind == .macContacts }
            ?? PersonBook(kind: .macContacts, name: "Контакты macOS", accountID: "mac")
        book.state = .connected
        book.lastError = nil
        book.pausedUntil = nil
        try await store.saveBook(book)
        adapters[book.id] = nil
        _ = try await readBook(id: book.id)
        return try await store.book(id: book.id) ?? book
    }

    /// Disconnects a book: its password goes first, its cards stay in the book as not managed.
    public func removeBook(id: UUID) async throws {
        guard let book = try await store.book(id: id) else { throw PersonsFailure.notFound }
        try? await vault.removePassword(bookID: id)
        adapters[id] = nil
        capabilities[id] = nil
        lastRemote[id] = nil
        if book.isAddressBookSource { _ = try persons.clearAddressBook(fromSource: book.source) }
        try await store.removeBook(id: id)
    }

    /// Switches of one account. Dropping «её контакты — моя адресная книга» clears the flags it set;
    /// raising it flags the persons this book already gave.
    public func setBookOptions(
        id: UUID, readBook: Bool?, isAddressBookSource: Bool?, acceptsAddressBook: Bool?, collectConversations: Bool?,
        enrichAutomatically: Bool? = nil
    ) async throws {
        guard var book = try await store.book(id: id) else { throw PersonsFailure.notFound }
        if let readBook, book.kind.isBook { book.readBook = readBook }
        if let enrichAutomatically, book.kind.isBook { book.enrichAutomatically = enrichAutomatically }
        if let acceptsAddressBook, book.kind.isBook { book.acceptsAddressBook = acceptsAddressBook }
        if let collectConversations, book.kind.hasConversations { book.collectConversations = collectConversations }
        if let isAddressBookSource, book.kind.isBook, isAddressBookSource != book.isAddressBookSource {
            book.isAddressBookSource = isAddressBookSource
            if isAddressBookSource {
                for person in try persons.persons()
                where person.identities.contains(where: { $0.service == book.kind.service && $0.accountID == book.accountID }) {
                    try persons.setAddressBook(personID: person.id, true, origin: .sourceAccount(book.source))
                }
            } else {
                _ = try persons.clearAddressBook(fromSource: book.source)
            }
        }
        try await store.saveBook(book)
        if acceptsAddressBook == true || isAddressBookSource == true { requestWritePass() }
    }

    /// «Повторный вход» or a reconnect: the book is connected again and read.
    public func reconnect(id: UUID) async throws {
        guard var book = try await store.book(id: id) else { throw PersonsFailure.notFound }
        book.state = .connected
        book.lastError = nil
        book.pausedUntil = nil
        adapters[id] = nil
        try await store.saveBook(book)
        _ = try await readBook(id: id)
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
        lastRemote = [:]
        authoritativeRemote = []
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
