import Foundation
import MakoshCore
import MakoshFiles
import SwiftUI

/// A file waiting on the send sheet.
struct FileSendRequest: Identifiable {
    let id = UUID()
    let handoff: FileHandoff
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
    @Published private(set) var configured = false
    /// Set by any "Отправить в Paperless…" item; the workspace shows the sheet.
    @Published var pendingSend: FileSendRequest?
    private var repository: ArchiveFileRepository?
    private var repositoryFactory: (@Sendable () throws -> ArchiveFileRepository)?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Makosh", isDirectory: true)
        vault = FileStorageTokenVault()
        registry = FileStorageRegistry(vault: vault)
        sender = PaperlessSender(registry: registry, vault: vault, journal: support.appendingPathComponent("PaperlessSubmissions.json"))
        model = FilesWorkspaceModel(catalogue: nil, registry: registry, vault: vault, sender: sender, resolver: nil)
    }

    /// Opens the catalogue over the shared archive schema; export uses the same S3 configuration as every service.
    func start(configuration: ContactWorkspaceConfiguration, resolver: (any FileSourceResolving)?) {
        guard !configured else { return }
        configured = true
        let schema = configuration.archiveSchema ?? configuration.schema
        model.attach(catalogue: FileCatalogue(connectionString: configuration.connectionString, schema: schema), resolver: resolver)
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
}
