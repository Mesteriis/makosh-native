import Foundation

/// Connection configuration is read by the Contacts service, never by the UI executor.
public struct PersonWorkspaceConfiguration: Decodable, Sendable {
    public let connectionString: String
    public let schema: String
    public let archiveSchema: String?
    private enum CodingKeys: String, CodingKey { case connectionString, schema, archiveSchema }
    public init(connectionString: String, schema: String = "makosh", archiveSchema: String? = nil) {
        self.connectionString = connectionString
        self.schema = schema
        self.archiveSchema = archiveSchema
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        connectionString = try values.decode(String.self, forKey: .connectionString)
        schema = try values.decodeIfPresent(String.self, forKey: .schema) ?? "makosh"
        archiveSchema = try values.decodeIfPresent(String.self, forKey: .archiveSchema)
    }
}

/// Only value snapshots cross from the serialized service to the presentation layer.
public struct PersonWorkspaceSnapshot: Sendable {
    public let persons: [Person]
    public let duplicates: [DuplicateCandidate]
    public let merges: [MergeRecord]
}

public struct PersonWorkspaceOpened: Sendable {
    public let configuration: PersonWorkspaceConfiguration
    public let snapshot: PersonWorkspaceSnapshot
}

public enum PersonWorkspaceCommand: Sendable {
    case save(draft: PersonDraft, id: UUID?)
    case addNote(contactID: UUID, text: String)
    case addSourceNote(contactID: UUID, note: PersonNote)
    case link(ImportedPerson, source: ImportSource, fetchedAt: Date, contactID: UUID?)
    case importFile(URL)
    case merge(survivorID: UUID, removedID: UUID)
    case undo(UUID)
    case setAIAccess(contactID: UUID, access: AIContactAccess)
}

public struct PersonWorkspaceWriteResult: Sendable {
    public enum Value: Equatable, Sendable {
        case saved(UUID), noted, sourceNoted(UUID), linked(UUID), imported(ImportResult), merged(UUID), undone, aiAccessSet
    }
    public let value: Value
    /// Nil means the write committed but its display refresh failed. Never replay it.
    public let snapshot: PersonWorkspaceSnapshot?
}

public enum PersonWorkspaceError: LocalizedError, Equatable, Sendable {
    case setup, missingConfigurationPath, explicitConfigurationRequired, invalidExplicitConfiguration
    case unavailable, writesBlocked
    case operation(String, blocksWrites: Bool)
    public var blocksWrites: Bool {
        switch self {
        case .writesBlocked: true
        case .operation(_, let blocked): blocked
        default: false
        }
    }
    public var errorDescription: String? {
        let setup =
            "Не удалось открыть PostgreSQL. Запустите scripts/dev-db.sh up и scripts/run.sh. Проверьте файл конфигурации базы данных."
        switch self {
        case .setup: return setup
        case .missingConfigurationPath: return "После --database-config укажите путь к JSON-конфигурации базы. " + setup
        case .explicitConfigurationRequired: return "Синтетическая проверка требует --database-config с отдельной тестовой схемой."
        case .invalidExplicitConfiguration: return "Для этой проверки нужна отдельная тестовая схема выбранного сервиса."
        case .unavailable: return "Хранилище не открыто. Перезапустите приложение после устранения ошибки."
        case .writesBlocked:
            return
                "Результат предыдущего сохранения требует проверки. Не повторяйте действие. Проверьте подключение к PostgreSQL и откройте приложение заново."
        case .operation(let message, _): return message
        }
    }
}

/// Non-Sendable persistence stays exclusively inside PersonWorkspaceWorker.
protocol PersonWorkspacePersistence: AnyObject {
    func persons() throws -> [Person]
    func duplicateCandidates() throws -> [DuplicateCandidate]
    func mergeHistory() throws -> [MergeRecord]
    func createPerson(draft: PersonDraft) throws -> UUID
    func updatePerson(id: UUID, draft: PersonDraft) throws
    func addNote(contactID: UUID, text: String) throws
    func addSourceNote(contactID: UUID, note: PersonNote) throws -> UUID
    func importDocument(_ document: ImportDocument) throws -> ImportResult
    func linkImportedPerson(_ incoming: ImportedPerson, source: ImportSource, fetchedAt: Date, contactID: UUID?) throws -> UUID
    func merge(survivorID: UUID, removedID: UUID) throws -> UUID
    func undoMerge(id: UUID) throws
    func setAIAccess(contactID: UUID, access: AIContactAccess) throws
}
extension PersonStore: PersonWorkspacePersistence {}
extension PersonWorkspacePersistence {
    /// Stores that predate AI access refuse it instead of silently ignoring it.
    func setAIAccess(contactID: UUID, access: AIContactAccess) throws { throw PersonWorkspaceError.unavailable }
}

/// Owns configuration IO, connection creation, SQL, import decoding and duplicate analysis.
/// Methods contain no suspension points: each write and its refresh finish before another
/// command can use the connection. No retry occurs after a failed or uncertain COMMIT.
public actor PersonWorkspaceWorker {
    private enum ConfigurationSource: Sendable {
        case arguments([String], requireExplicit: Bool, syntheticSchemaPrefix: String)
        case value(PersonWorkspaceConfiguration)
    }
    private let source: ConfigurationSource
    private let storeFactory: @Sendable (PersonWorkspaceConfiguration) throws -> any PersonWorkspacePersistence
    private var store: (any PersonWorkspacePersistence)?
    private var configuration: PersonWorkspaceConfiguration?
    private var blocked = false

    public init(
        arguments: [String] = CommandLine.arguments, requireExplicitDatabaseConfiguration: Bool = false,
        syntheticSchemaPrefix: String = "qa_telegram_dossier_"
    ) {
        source = .arguments(arguments, requireExplicit: requireExplicitDatabaseConfiguration, syntheticSchemaPrefix: syntheticSchemaPrefix)
        storeFactory = { try PersonStore(connectionString: $0.connectionString, schema: $0.schema) }
    }
    init(
        configuration: PersonWorkspaceConfiguration,
        storeFactory: @escaping @Sendable (PersonWorkspaceConfiguration) throws -> any PersonWorkspacePersistence = {
            try PersonStore(connectionString: $0.connectionString, schema: $0.schema)
        }
    ) {
        source = .value(configuration)
        self.storeFactory = storeFactory
    }

    public func open() throws -> PersonWorkspaceOpened {
        if let configuration, store != nil {
            return try .init(configuration: configuration, snapshot: snapshot())
        }
        do {
            let configuration = try readConfiguration()
            store = try storeFactory(configuration)
            let snapshot = try snapshot()
            self.configuration = configuration
            return .init(configuration: configuration, snapshot: snapshot)
        } catch {
            store = nil
            if let safe = error as? PersonWorkspaceError { throw safe }
            // Decoding and connection diagnostics may embed credentials or local paths.
            throw PersonWorkspaceError.setup
        }
    }

    public func snapshot() throws -> PersonWorkspaceSnapshot {
        guard let store else { throw PersonWorkspaceError.unavailable }
        return try .init(persons: store.persons(), duplicates: store.duplicateCandidates(), merges: store.mergeHistory())
    }

    public func apply(_ command: PersonWorkspaceCommand) throws -> PersonWorkspaceWriteResult {
        guard let store else { throw PersonWorkspaceError.unavailable }
        guard !blocked else { throw PersonWorkspaceError.writesBlocked }
        if case .addSourceNote = command { try Task.checkCancellation() }
        // File access and decoding happen before entering a possible database mutation.
        let document: ImportDocument?
        if case .importFile(let url) = command {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { document = try ImportDocument.decode(Data(contentsOf: url)) } catch {
                throw PersonWorkspaceError.operation(
                    "Не удалось прочитать JSON-файл контактов. Проверьте формат файла.", blocksWrites: false)
            }
        } else {
            document = nil
        }

        let value: PersonWorkspaceWriteResult.Value
        do {
            switch command {
            case .save(let draft, let id):
                if let id {
                    try store.updatePerson(id: id, draft: draft)
                    value = .saved(id)
                } else {
                    value = try .saved(store.createPerson(draft: draft))
                }
            case .addNote(let id, let text):
                try store.addNote(contactID: id, text: text)
                value = .noted
            case .addSourceNote(let id, let note): value = .sourceNoted(try store.addSourceNote(contactID: id, note: note))
            case .link(let incoming, let source, let fetchedAt, let id):
                value = try .linked(store.linkImportedPerson(incoming, source: source, fetchedAt: fetchedAt, contactID: id))
            case .importFile:
                guard let document else { throw PersonWorkspaceError.unavailable }
                value = try .imported(store.importDocument(document))
            case .merge(let survivor, let removed):
                _ = try store.merge(survivorID: survivor, removedID: removed)
                value = .merged(survivor)
            case .undo(let id):
                try store.undoMerge(id: id)
                value = .undone
            case .setAIAccess(let id, let access):
                try store.setAIAccess(contactID: id, access: access)
                value = .aiAccessSet
            }
        } catch {
            let safe = mutationError(error)
            blocked = safe.blocksWrites
            throw safe
        }
        do { return try .init(value: value, snapshot: snapshot()) } catch {
            // Returning the committed identity/count lets the UI close its editor and
            // keep the successful link even when the visible snapshot cannot refresh.
            blocked = true
            return .init(value: value, snapshot: nil)
        }
    }

    private func mutationError(_ error: Error) -> PersonWorkspaceError {
        if let error = error as? StoreError {
            switch error {
            case .database: return .writesBlocked
            default: return .operation(error.localizedDescription, blocksWrites: false)
            }
        }
        return .writesBlocked
    }

    private func readConfiguration() throws -> PersonWorkspaceConfiguration {
        let configuration: PersonWorkspaceConfiguration
        let requireExplicit: Bool
        let syntheticSchemaPrefix: String
        switch source {
        case .value(let value):
            configuration = value
            requireExplicit = false
            syntheticSchemaPrefix = "qa_telegram_dossier_"
        case .arguments(let arguments, let explicit, let prefix):
            requireExplicit = explicit
            syntheticSchemaPrefix = prefix
            let url: URL
            if let index = arguments.firstIndex(of: "--database-config") {
                guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                    throw PersonWorkspaceError.missingConfigurationPath
                }
                url = URL(fileURLWithPath: arguments[index + 1])
            } else {
                guard !explicit else { throw PersonWorkspaceError.explicitConfigurationRequired }
                url = try FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
                )
                .appendingPathComponent("Makosh/database.json")
            }
            configuration = try JSONDecoder().decode(PersonWorkspaceConfiguration.self, from: Data(contentsOf: url))
        }
        guard
            !requireExplicit
                || (syntheticSchemaPrefix.hasPrefix("qa_") && ArchiveBackup.isValidSchemaName(syntheticSchemaPrefix)
                    && configuration.schema.hasPrefix(syntheticSchemaPrefix)
                    && (configuration.archiveSchema ?? configuration.schema).hasPrefix(syntheticSchemaPrefix))
        else {
            throw PersonWorkspaceError.invalidExplicitConfiguration
        }
        guard !configuration.connectionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            ArchiveBackup.isValidSchemaName(configuration.schema),
            configuration.archiveSchema.map(ArchiveBackup.isValidSchemaName) ?? true
        else { throw PersonWorkspaceError.setup }
        return configuration
    }
}
