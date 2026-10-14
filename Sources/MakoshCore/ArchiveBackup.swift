import Foundation
import CryptoKit

public struct ArchiveBackupSummary: Equatable, Sendable {
    public let vaultID: UUID
    public let messageVersions: Int64, files: Int, encryptedBytes: Int64
    public let databaseBytes: Int64
}
public struct ArchiveBackupInspection: Equatable, Sendable {
    public let summary: ArchiveBackupSummary
    public let fingerprint: String
}

public struct ArchiveBackupKeys: Sendable {
    let lookup: @Sendable (UUID) throws -> Data?
    let install: @Sendable (UUID, Data) throws -> Void
    public init(lookup: @escaping @Sendable (UUID) throws -> Data?, install: @escaping @Sendable (UUID, Data) throws -> Void) {
        self.lookup = lookup; self.install = install
    }
    public static var keychain: Self { .init(lookup: MessageArchiveKeychain.existing, install: MessageArchiveKeychain.install) }
    public func requireExisting(_ vaultID: UUID) throws -> Data {
        guard let value = try lookup(vaultID), value.count == 32 else { throw ArchiveBackupError.keyUnavailable }
        return value
    }
}

public enum ArchiveBackupError: Error, LocalizedError, Equatable {
    case invalid, integrity, unsupported, keyUnavailable, conflict, incomplete, storageUnavailable, disabledObjectMissing, policyChanged, changed, noArchive
    public var errorDescription: String? {
        switch self {
        case .invalid: "Некорректный путь, состав или размер резервной копии."
        case .integrity: "Проверка целостности не пройдена. Проверьте резервную копию и ключ восстановления."
        case .unsupported: "Версия резервной копии не поддерживается."
        case .keyUnavailable: "Ключ архива недоступен. Новый ключ не создаётся."
        case .conflict: "Назначение уже существует или содержит другие данные. Перезапись запрещена."
        case .incomplete: "Архив или копия не завершены. Дождитесь сохранения файлов и повторите."
        case .storageUnavailable: "Для файлов требуется подключённое S3-хранилище с подходящими объектами."
        case .disabledObjectMissing: "В S3 отсутствует файл чата с выключенным сохранением. Новые копии не созданы. Используйте исходное хранилище."
        case .policyChanged: "Политика сохранения изменилась. Восстановление архива не опубликовано."
        case .changed: "Выбранная копия изменилась. Проверьте её заново перед восстановлением."
        case .noArchive: "Постоянный архив ещё не создан. Сохранённых сообщений нет."
        }
    }
}

public enum ArchiveBackup {
    public static func isValidSchemaName(_ schema: String) -> Bool {
        let bytes = Array(schema.utf8)
        return !bytes.isEmpty && bytes.count <= 63 && (97...122).contains(bytes[0])
            && bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
    public static func export(connectionString: String, schema: String, configuration: S3ObjectStoreConfiguration? = nil,
                              to destination: URL, recoveryKey: URL, keys: ArchiveBackupKeys = .keychain) async throws -> ArchiveBackupSummary {
        let storage: (any ArchiveBackupObjectStorage)? = try configuration.map(ArchiveBackupS3Storage.init)
        return try await export(connectionString: connectionString, schema: schema, storage: storage, to: destination, recoveryKey: recoveryKey, keys: keys)
    }
    public static func inspect(package: URL, recoveryKey: URL) throws -> ArchiveBackupSummary {
        try inspectReceipt(package: package, recoveryKey: recoveryKey).summary
    }
    public static func inspectReceipt(package: URL, recoveryKey: URL) throws -> ArchiveBackupInspection {
        do {
            let verified = try ArchiveBackupVerified.open(package: package, recoveryKey: recoveryKey)
            return .init(summary: verified.header.summary, fingerprint: verified.fingerprint)
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as ArchiveBackupError { throw error }
        catch { throw ArchiveBackupError.integrity }
    }
    public static func restore(package: URL, recoveryKey: URL, connectionString: String, schema: String,
                               configuration: S3ObjectStoreConfiguration? = nil, keys: ArchiveBackupKeys = .keychain,
                               currentPolicy: @Sendable (MessageArchiveIdentity) async throws -> Bool? = { _ in nil },
                               currentOffPolicies: @Sendable () async throws -> [MessageArchiveIdentity] = { [] },
                               expectedFingerprint: String? = nil) async throws -> ArchiveBackupSummary {
        let storage: (any ArchiveBackupObjectStorage)? = try configuration.map(ArchiveBackupS3Storage.init)
        return try await restore(package: package, recoveryKey: recoveryKey, connectionString: connectionString, schema: schema,
            storage: storage, keys: keys, currentPolicy: currentPolicy, currentOffPolicies: currentOffPolicies, expectedFingerprint: expectedFingerprint)
    }
}

extension ArchiveBackup {
    static func restore(package: URL, recoveryKey: URL, connectionString: String, schema: String,
                        storage: (any ArchiveBackupObjectStorage)?, keys: ArchiveBackupKeys,
                        currentPolicy: @Sendable (MessageArchiveIdentity) async throws -> Bool? = { _ in nil },
                        currentOffPolicies: @Sendable () async throws -> [MessageArchiveIdentity] = { [] },
                        expectedFingerprint: String? = nil) async throws -> ArchiveBackupSummary {
        let verified = try ArchiveBackupVerified.open(package: package, recoveryKey: recoveryKey)
        if let expectedFingerprint {
            guard ArchiveBackupCryptography.validHash(expectedFingerprint) else { throw ArchiveBackupError.invalid }
            guard verified.fingerprint == expectedFingerprint else { throw ArchiveBackupError.changed }
        }
        return try await restoreVerified(verified, connectionString: connectionString, schema: schema, storage: storage, keys: keys,
            currentPolicy: currentPolicy, currentOffPolicies: currentOffPolicies)
    }
    static func export(connectionString: String, schema: String, storage: (any ArchiveBackupObjectStorage)?,
                       to destination: URL, recoveryKey: URL, keys: ArchiveBackupKeys) async throws -> ArchiveBackupSummary {
        guard destination.isFileURL, recoveryKey.isFileURL, destination.pathExtension.lowercased() == "makoshbackup",
              recoveryKey.pathExtension.lowercased() == "makoshkey",
              !recoveryKey.path.hasPrefix(destination.path + "/") else { throw ArchiveBackupError.invalid }
        let parent = try ArchiveBackupDirectory(destination.deletingLastPathComponent(), requireTrustedParents: true)
        let keyParent = try ArchiveBackupDirectory(recoveryKey.deletingLastPathComponent(), requireTrustedParents: true)
        try parent.requireAbsent(destination.lastPathComponent); try keyParent.requireAbsent(recoveryKey.lastPathComponent)
        guard try ArchiveBackupDestination.archiveExists(connectionString: connectionString, schema: schema) else { throw ArchiveBackupError.noArchive }
        let stagingName = ".makosh-backup-\(UUID().uuidString.lowercased())", staging = try parent.createDirectory(stagingName)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging.url) } }
        let database = try staging.createDirectory("database"), objectsDirectory = try staging.createDirectory("objects")
        let workspace = try ArchiveBackupWorkspace()
        let backupID = UUID(), recovery = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var rootKey: Data?
        let source = try MessageArchiveStore(connectionString: connectionString, schema: schema, readOnly: true) { id, mayCreate in
            guard !mayCreate, let key = try keys.lookup(id), key.count == 32 else { throw ArchiveBackupError.keyUnavailable }
            rootKey = key; return key
        }
        let vaultID = try source.fileVault().id
        guard let rootKey else { throw ArchiveBackupError.keyUnavailable }
        let validator = try ArchiveBackupRowValidator(vaultID: vaultID, rootKey: rootKey)
        let writer = ArchiveBackupPartWriter(directory: database, workspace: workspace.directory, recovery: recovery, id: backupID)
        try source.writeBackupSnapshot { row in
            try validator.accept(row); try writer.write(ArchiveBackupRecordReader.frame(row))
        }
        let objects = try validator.finish(), databaseHash = try writer.finish()
        for object in objects {
            try Task.checkCancellation()
            guard let storage, object.record.storageID == storage.storageID || validator.aliases.contains(object.record.storageID + "\0" + storage.storageID) else { throw ArchiveBackupError.storageUnavailable }
            let record = object.record, encrypted = objectsDirectory.url.appendingPathComponent(ArchiveBackupFormat.objectName(record.id))
            try await storage.download(key: record.objectKey, to: encrypted, sha256: record.sha256, byteCount: record.byteCount)
            try ArchiveBackupFormat.verifyObject(record, encrypted: encrypted, workspace: workspace.directory, crypto: validator.crypto)
        }
        let header = ArchiveBackupHeader(vaultID: vaultID, rootKey: rootKey, partCount: writer.partCount,
            databaseBytes: writer.totalBytes, databaseHash: databaseHash, counts: validator.counts, objectCount: objects.count,
            objectBytes: objects.reduce(0) { $0 + $1.record.byteCount }, sourceStorageID: storage?.storageID)
        let headerFile = try staging.file("header.json", create: true)
        try headerFile.write(ArchiveBackupFormat.headerData(header, recovery: recovery, id: backupID)); try headerFile.sync()
        try objectsDirectory.sync(); try staging.sync()
        try Task.checkCancellation()
        // Different directories cannot be committed atomically together. An unused
        // recovery file may remain after a late publication failure; it is never overwritten.
        let keyFile = try keyParent.file(recoveryKey.lastPathComponent, create: true)
        try keyFile.write(ArchiveBackupFormat.recoveryData(recovery, id: backupID)); try keyFile.sync(); try keyParent.sync()
        try parent.publish(stagingName, as: destination.lastPathComponent, expected: staging); published = true
        return header.summary
    }
}
