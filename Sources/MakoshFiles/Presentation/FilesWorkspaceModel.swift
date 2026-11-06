import Foundation
import MakoshCore

/// The catalogue as the section sees it; the real actor conforms, tests stub it.
public protocol FileCatalogueReading: Sendable {
    func refresh(resolver: (any FileSourceResolving)?) async throws -> [FileCatalogueItem]
}

extension FileCatalogue: FileCatalogueReading {}

public enum FilesSource: Hashable, Sendable {
    case all
    case service(String)
    case storage(UUID)
}

public enum FilesSort: Sendable, Equatable {
    case dateDescending, name
}

public struct PaperlessLists: Equatable, Sendable {
    public let tags: [PaperlessNamed]
    public let types: [PaperlessNamed]
    public init(tags: [PaperlessNamed], types: [PaperlessNamed]) {
        self.tags = tags
        self.types = types
    }
}

/// State of the Files section. Every asynchronous load remembers the
/// generation of the selection it serves and drops a late result.
@MainActor public final class FilesWorkspaceModel: ObservableObject {
    @Published public var source: FilesSource = .all {
        didSet { if source != oldValue { sourceChanged() } }
    }
    @Published public var search = "" { didSet { applyFilters() } }
    @Published public var category: FileCategory? { didSet { applyFilters() } }
    @Published public var sort: FilesSort = .dateDescending { didSet { applyFilters() } }
    @Published public private(set) var items: [FileCatalogueItem] = []
    @Published public private(set) var visible: [FileCatalogueItem] = []
    @Published public private(set) var connections: [FileStorageConnection] = []
    @Published public private(set) var storageStatus: [UUID: Result<PaperlessStatus, FilesFailure>] = [:]
    @Published public private(set) var documents: [PaperlessDocument] = []
    @Published public private(set) var hasMoreDocuments = false
    @Published public private(set) var documentQuery = ""
    @Published public private(set) var loading = false
    @Published public private(set) var loadingDocuments = false
    @Published public var error: String?
    @Published public private(set) var submissions: [PaperlessSubmission] = []
    @Published public private(set) var lists: [UUID: PaperlessLists] = [:]
    /// A catalogue row to select when the section opens (from an AI card).
    @Published public var highlighted: UUID?

    public let sender: PaperlessSender
    private var catalogue: (any FileCatalogueReading)?
    private let registry: FileStorageRegistry
    private let vault: FileStorageTokenVault
    private var resolver: (any FileSourceResolving)?
    private let clientFactory: PaperlessSender.ClientFactory
    private let pollInterval: Duration
    private var generation = 0
    private var documentPage = 0
    private var documentsTask: Task<Void, Never>?
    private var polling: Task<Void, Never>?

    public init(
        catalogue: (any FileCatalogueReading)?, registry: FileStorageRegistry, vault: FileStorageTokenVault, sender: PaperlessSender,
        resolver: (any FileSourceResolving)?,
        clientFactory: @escaping PaperlessSender.ClientFactory = { PaperlessClient(connection: $0, token: $1) },
        pollInterval: Duration = .seconds(30)
    ) {
        self.catalogue = catalogue
        self.registry = registry
        self.vault = vault
        self.sender = sender
        self.resolver = resolver
        self.clientFactory = clientFactory
        self.pollInterval = pollInterval
        connections = registry.connections()
    }

    // MARK: - Catalogue

    /// The archive opens after the database configuration is known.
    public func attach(catalogue: any FileCatalogueReading, resolver: (any FileSourceResolving)?) {
        self.catalogue = catalogue
        self.resolver = resolver
    }

    /// Reads the catalogue; the list is global, so it always applies, but the
    /// error belongs to the selection that asked.
    public func refresh() async {
        guard let catalogue, !loading else { return }
        loading = true
        defer { loading = false }
        let token = generation
        do {
            let result = try await catalogue.refresh(resolver: resolver)
            items = result
            if token == generation { error = nil }
            applyFilters()
        } catch {
            if token == generation { self.error = Self.describe(error) }
        }
        submissions = await sender.submissions()
        if let journalFailure = await sender.lastJournalFailure, token == generation { error = journalFailure }
        for connection in connections where storageStatus[connection.id] == nil { await test(connection.id) }
    }

    public func startPolling() {
        guard polling == nil else { return }
        let interval = pollInterval
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    public func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    private func applyFilters() {
        let needle = Self.fold(search.trimmingCharacters(in: .whitespacesAndNewlines))
        var result = items.filter { item in
            switch source {
            case .all: true
            case .service(let service): item.service == service
            case .storage: false
            }
        }
        if let category { result = result.filter { $0.category == category } }
        if !needle.isEmpty {
            result = result.filter { item in
                Self.fold(item.name).contains(needle) || Self.fold(item.sourceTitle ?? "").contains(needle)
                    || Self.fold(item.author ?? "").contains(needle)
            }
        }
        switch sort {
        case .dateDescending: result.sort { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
        case .name:
            result.sort {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
        }
        visible = result
    }

    private static func fold(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "ё", with: "е") }

    // MARK: - Storages

    public func save(_ connection: FileStorageConnection, token: String?) async throws {
        try await registry.save(connection, token: token)
        storageStatus[connection.id] = nil
        lists[connection.id] = nil
        reloadConnections()
    }

    public func remove(_ id: UUID) async throws {
        try await registry.remove(id)
        storageStatus[id] = nil
        lists[id] = nil
        reloadConnections()
    }

    public func reloadConnections() {
        connections = registry.connections()
        if case .storage(let id) = source, !connections.contains(where: { $0.id == id }) { source = .all }
    }

    private func sourceChanged() {
        generation += 1
        documentsTask?.cancel()
        documentsTask = nil
        documents = []
        hasMoreDocuments = false
        loadingDocuments = false
        documentQuery = ""
        documentPage = 0
        error = nil
        applyFilters()
        if case .storage = source { loadDocuments(query: "", page: 1) }
    }

    public func searchDocuments(_ query: String) async {
        guard case .storage = source else { return }
        documentsTask?.cancel()
        documents = []
        hasMoreDocuments = false
        loadDocuments(query: query, page: 1)
        await waitForDocuments()
    }

    public func loadMoreDocuments() async {
        guard case .storage = source, hasMoreDocuments, !loadingDocuments else { return }
        loadDocuments(query: documentQuery, page: documentPage + 1)
        await waitForDocuments()
    }

    /// Lets a caller follow the page load that a selection started.
    public func waitForDocuments() async {
        while let task = documentsTask {
            await task.value
            if documentsTask == task { documentsTask = nil }
        }
    }

    private func loadDocuments(query: String, page: Int) {
        guard case .storage(let id) = source else { return }
        let token = generation
        documentQuery = query
        loadingDocuments = true
        documentsTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<PaperlessPage<PaperlessDocument>, Error>
            if let client = await client(for: id) {
                do { result = .success(try await client.documents(query: query, page: page)) } catch { result = .failure(error) }
            } else {
                result = .failure(FilesFailure.unauthorized)
            }
            guard token == generation, !Task.isCancelled else { return }
            loadingDocuments = false
            switch result {
            case .success(let loaded):
                documents = page == 1 ? loaded.items : documents + loaded.items
                documentPage = page
                hasMoreDocuments = loaded.hasMore
                error = nil
            case .failure(let failure):
                error = Self.describe(failure)
            }
        }
    }

    public func test(_ id: UUID) async {
        guard let client = await client(for: id) else {
            storageStatus[id] = .failure(.unauthorized)
            return
        }
        do { storageStatus[id] = .success(try await client.status()) } catch let failure as FilesFailure {
            storageStatus[id] = .failure(failure)
        } catch { storageStatus[id] = .failure(.unexpectedResponse) }
    }

    public func lists(for id: UUID) async -> PaperlessLists? {
        guard let client = await client(for: id) else { return nil }
        do {
            let value = PaperlessLists(tags: try await client.tags(), types: try await client.documentTypes())
            lists[id] = value
            return value
        } catch {
            self.error = Self.describe(error)
            return nil
        }
    }

    public func download(documentID: Int, from id: UUID, original: Bool = true, to destination: URL) async throws {
        guard let client = await client(for: id) else { throw FilesFailure.unauthorized }
        try await client.download(id: documentID, original: original, to: destination)
    }

    public func documentURL(id documentID: Int, in connectionID: UUID) -> URL? {
        guard case .paperless(let connection)? = connections.first(where: { $0.id == connectionID }) else { return nil }
        return connection.baseURL.appendingPathComponent("documents/\(documentID)/details")
    }

    /// A client for the connection, or nil without a token.
    public func client(for id: UUID) async -> (any PaperlessServing)? {
        guard case .paperless(let connection)? = registry.connections().first(where: { $0.id == id }) else { return nil }
        guard let token = try? await vault.load(connectionID: connection.id) else { return nil }
        return clientFactory(connection, token)
    }

    // MARK: - Sending

    public func send(
        _ handoff: FileHandoff, to connectionID: UUID, options: PaperlessUpload, id: UUID = UUID()
    ) async -> PaperlessSubmission {
        let result = await sender.send(handoff, to: connectionID, options: options, id: id) { submission in
            Task { @MainActor [weak self] in self?.apply(submission) }
        }
        apply(result)
        return result
    }

    public func check(_ id: UUID) async {
        if let submission = await sender.check(id) { apply(submission) }
    }

    private func apply(_ submission: PaperlessSubmission) {
        if let index = submissions.firstIndex(where: { $0.id == submission.id }) {
            submissions[index] = submission
        } else {
            submissions.append(submission)
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? FilesFailure)?.errorDescription ?? (error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error))
    }
}
