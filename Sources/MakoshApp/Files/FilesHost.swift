import Foundation
import MakoshAI
import MakoshCore
import MakoshFiles
import SwiftUI

/// A file waiting on the send sheet.
struct FileSendRequest: Identifiable {
    let id = UUID()
    let handoff: FileHandoff
}

/// A file waiting on the forward sheet: to a chat or by mail.
struct FileForwardRequest: Identifiable {
    enum Mode { case chat, mail }
    let id = UUID()
    let handoff: FileHandoff
    let mode: Mode
}

/// A file to attach to a new AI conversation; `source` avoids staging when the
/// file already has an archive record or lives in Paperless.
struct FileAskRequest: Identifiable {
    let id = UUID()
    let handoff: FileHandoff
    let source: AIFileSource?
}

/// The Files host reaches every view through the environment; views shown
/// without it (tests, isolated previews) simply offer no sending.
private struct FilesHostKey: EnvironmentKey {
    static let defaultValue: FilesHost? = nil
}

extension EnvironmentValues {
    var filesHost: FilesHost? {
        get { self[FilesHostKey.self] }
        set { self[FilesHostKey.self] = newValue }
    }
}

/// One Files model per process, shared by the workspace window and the
/// settings scene. The workspace hands over the database configuration once
/// its own load has resolved it.
@MainActor final class FilesHost: ObservableObject {
    let registry: FileStorageRegistry
    let vault: FileStorageTokenVault
    let sender: PaperlessSender
    let model: FilesWorkspaceModel
    /// Private copies for composers and AI cards; cleared at launch.
    let stage: FileHandoffStage
    @Published private(set) var configured = false
    /// Set by any "Отправить в Paperless…" item; the workspace shows the sheet.
    @Published var pendingSend: FileSendRequest?
    @Published var pendingForward: FileForwardRequest?
    @Published var pendingAsk: FileAskRequest?
    private var repository: ArchiveFileRepository?
    private var repositoryFactory: (@Sendable () throws -> ArchiveFileRepository)?

    /// Synthetic previews export placeholder bytes instead of reading S3.
    private let syntheticBytes: Data?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Makosh", isDirectory: true)
        vault = FileStorageTokenVault()
        registry = FileStorageRegistry(vault: vault)
        sender = PaperlessSender(registry: registry, vault: vault, journal: support.appendingPathComponent("PaperlessSubmissions.json"))
        model = FilesWorkspaceModel(catalogue: nil, registry: registry, vault: vault, sender: sender, resolver: nil)
        syntheticBytes = nil
        stage = FileHandoffStage(root: support.appendingPathComponent("FileHandoffStage", isDirectory: true))
        Task { [stage] in await stage.clearAll() }
    }

    #if DEBUG
    /// Isolated QA: in-memory tokens, a separate defaults suite, a journal in a
    /// temporary directory and a Paperless that never touches the network.
    init(synthetic journal: URL, defaults: UserDefaults, paperless: any PaperlessServing) {
        vault = FileStorageTokenVault(access: .memory())
        registry = FileStorageRegistry(defaults: defaults, vault: vault)
        let factory: PaperlessSender.ClientFactory = { _, _ in paperless }
        sender = PaperlessSender(registry: registry, vault: vault, journal: journal, clientFactory: factory)
        model = FilesWorkspaceModel(catalogue: nil, registry: registry, vault: vault, sender: sender, resolver: nil, clientFactory: factory)
        syntheticBytes = Data("%PDF-1.7\n% synthetic archive copy\n".utf8)
        stage = FileHandoffStage(root: journal.deletingLastPathComponent().appendingPathComponent("stage", isDirectory: true))
    }
    #endif

    /// Opens the catalogue over the shared archive schema; export uses the same S3 configuration as every service.
    func start(
        configuration: PersonWorkspaceConfiguration, resolver: (any FileSourceResolving)?,
        keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open
    ) {
        guard !configured else { return }
        configured = true
        let schema = configuration.archiveSchema ?? configuration.schema
        model.attach(
            catalogue: FileCatalogue(connectionString: configuration.connectionString, schema: schema, keyProvider: keyProvider),
            resolver: resolver)
        if syntheticBytes != nil { return }
        let args = CommandLine.arguments
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Makosh", isDirectory: true)
        let storage: URL
        if let index = args.firstIndex(of: "--storage-config"), args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") {
            storage = URL(fileURLWithPath: args[index + 1])
        } else {
            storage = support.appendingPathComponent("s3.json")
        }
        let connection = configuration.connectionString, spool = support.appendingPathComponent("FileArchiveQueue", isDirectory: true)
        repositoryFactory = {
            try ArchiveFileRepository(
                connectionString: connection, schema: schema, configuration: S3ConfigurationFile.read(storage), spoolDirectory: spool)
        }
        Task { await sender.resume() }
    }

    private func openRepository() async throws -> ArchiveFileRepository {
        if let repository { return repository }
        guard let factory = repositoryFactory else { throw FilesFailure.archiveUnavailable }
        do {
            let value = try await BackgroundWork.run { try factory() }
            repository = value
            return value
        } catch { throw FilesFailure.archiveUnavailable }
    }

    /// Verified bytes of a retained file, through a private staging copy.
    private func export(_ item: FileCatalogueItem, into destination: URL) async throws {
        if let syntheticBytes {
            try syntheticBytes.write(to: destination, options: .withoutOverwriting)
            return
        }
        let repository = try await openRepository()
        do { try await repository.export(item.record, to: destination) } catch { throw FilesFailure.integrity }
    }

    /// Saves to a path the person chose; an existing file there is replaced only after verification.
    func export(_ item: FileCatalogueItem, to destination: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "makosh-file-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("file")
        try await export(item, into: staged)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    func preview(_ item: FileCatalogueItem) async throws -> FilePreviewLease {
        try await FilePreviewLease.create(name: item.name) { [self] url in try await self.export(item, into: url) }
    }

    func handoff(_ item: FileCatalogueItem) -> FileHandoff {
        FileHandoff(name: item.name, byteCount: item.byteCount, date: item.date) { [self] url in try await self.export(item, into: url) }
    }

    /// A catalogue row by its archive record id, after the catalogue has been read.
    func record(id: UUID) async -> FileCatalogueItem? {
        if let item = model.items.first(where: { $0.id == id }) { return item }
        // A read already under way answers soon; a second refresh is a no-op while it runs.
        for _ in 0..<200 where model.loading { try? await Task.sleep(for: .milliseconds(50)) }
        if let item = model.items.first(where: { $0.id == id }) { return item }
        await model.refresh()
        return model.items.first { $0.id == id }
    }

    /// The original of a Paperless document into a private destination.
    func downloadPaperless(connectionID: UUID, documentID: Int, to destination: URL) async throws {
        try await model.download(documentID: documentID, from: connectionID, original: true, to: destination)
    }

    func paperlessDetail(connectionID: UUID, documentID: Int) async throws -> PaperlessDocumentDetail {
        guard let client = await model.client(for: connectionID) else { throw FilesFailure.storageMissing }
        return try await client.document(id: documentID)
    }

    func handoff(connectionID: UUID, document: PaperlessDocument) -> FileHandoff {
        let name = document.originalFileName.map { URL(fileURLWithPath: $0).lastPathComponent } ?? (document.title + ".pdf")
        return FileHandoff(name: name, date: document.created) { [self] url in
            try await self.downloadPaperless(connectionID: connectionID, documentID: document.id, to: url)
        }
    }
}
