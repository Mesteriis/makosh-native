import Foundation
import CryptoKit
import Darwin

public struct ArchiveFileCaptureFailure: Error {
    public let isQueued: Bool
}

public enum S3ConfigurationFile {
    public static func read(_ url: URL) throws -> S3ObjectStoreConfiguration {
        guard url.isFileURL else { throw S3ObjectStoreError.configuration }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw S3ObjectStoreError.configuration }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 16384 else { throw S3ObjectStoreError.configuration }
        var bytes = Data(count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress,$0.count) }
        guard count == bytes.count else { throw S3ObjectStoreError.configuration }
        do { return try JSONDecoder().decode(S3ObjectStoreConfiguration.self,from: bytes) }
        catch { throw S3ObjectStoreError.configuration }
    }
}

/// The queue contains encrypted envelopes and encrypted metadata only. S3 success
/// precedes a stored receipt in PostgreSQL; failed/uncertain operations retain the queue.
public actor ArchiveFileRepository {
    private let connectionString: String
    private let schema: String
    private let configuration: S3ObjectStoreConfiguration
    private let spool: URL
    private let keyProvider: @Sendable (UUID,Bool) throws -> Data
    private var store: MessageArchiveStore?
    private var vault: ArchiveFileVault?
    private let storage: S3ObjectStore
    private let directorySync: @Sendable (URL) throws -> Void
    private var processing = Set<UUID>()
    private let readOnly: Bool
    public init(connectionString: String, schema: String, configuration: S3ObjectStoreConfiguration,
                spoolDirectory: URL, readOnly: Bool = false, keyProvider: @escaping @Sendable (UUID,Bool) throws -> Data = MessageArchiveKeychain.open) throws {
        try self.init(connectionString: connectionString,schema: schema,configuration: configuration,
                      spoolDirectory: spoolDirectory,keyProvider: keyProvider,directorySync: Self.syncDirectory,readOnly: readOnly)
    }
    init(connectionString: String, schema: String, configuration: S3ObjectStoreConfiguration,
         spoolDirectory: URL, keyProvider: @escaping @Sendable (UUID,Bool) throws -> Data,
         directorySync: @escaping @Sendable (URL) throws -> Void, readOnly: Bool = false) throws {
        self.connectionString = connectionString; self.schema = schema; self.configuration = configuration
        self.spool = spoolDirectory; self.keyProvider = keyProvider
        self.directorySync = directorySync
        self.storage = try S3ObjectStore(configuration: configuration)
        self.readOnly = readOnly
    }
    private var storageID: String {
        SHA256.hash(data: Data((configuration.endpoint + "\u{0}" + configuration.region + "\u{0}" + configuration.bucket).utf8)).map { String(format: "%02x",$0) }.joined()
    }
    private func localStorageID(_ vault: ArchiveFileVault) -> String {
        SHA256.hash(data: Data("makosh-local-preparation-v1|\(vault.id.uuidString)".utf8)).map { String(format: "%02x",$0) }.joined()
    }
    private func open() throws -> MessageArchiveStore {
        if let store { return store }
        let result = try MessageArchiveStore(connectionString: connectionString,schema: schema,readOnly: readOnly,keyProvider: keyProvider)
        store = result; return result
    }
    private func keys() throws -> ArchiveFileVault {
        if let vault { return vault }
        let result = try open().fileVault(); vault = result; return result
    }
    private func prepareSpool() throws {
        guard spool.isFileURL else { throw MessageArchiveError.invalid }
        try FileManager.default.createDirectory(at: spool,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(spool.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MessageArchiveError.integrity }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw MessageArchiveError.integrity }
    }
    private func envelope(_ id: UUID) -> URL { spool.appendingPathComponent(id.uuidString.lowercased() + ".envelope") }
    private func manifest(_ id: UUID, local: Bool = false) -> URL {
        spool.appendingPathComponent(id.uuidString.lowercased() + (local ? ".local" : ".receipt"))
    }
    private func binding(_ id: UUID, _ vault: ArchiveFileVault, local: Bool = false) -> Data {
        Data("\(local ? "makosh-local-preparation-v1" : "makosh-file-queue-v1")|\(vault.id.uuidString)|\(id.uuidString)".utf8)
    }
    private func save(_ record: ArchiveFileRecord, vault: ArchiveFileVault, published: () -> Void) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= 16384, let sealed = try AES.GCM.seal(data,using: SymmetricKey(data: vault.key),authenticating: binding(record.id,vault,local: record.state == .local)).combined else { throw MessageArchiveError.invalid }
        let temporary = spool.appendingPathComponent(UUID().uuidString + ".preparing")
        let fd = Darwin.open(temporary.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw MessageArchiveError.integrity }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try sealed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd,bytes.baseAddress!.advanced(by: offset),bytes.count-offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MessageArchiveError.database }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw MessageArchiveError.database }
        // link publishes without replacing any existing queue receipt.
        guard link(temporary.path,manifest(record.id,local: record.state == .local).path) == 0 else { throw MessageArchiveError.integrity }
        // Even if directory fsync is uncertain, reconcile this visible receipt;
        // recapturing would create a second object for the same delivered file.
        published()
        try directorySync(spool)
    }
    private func load(_ id: UUID,vault: ArchiveFileVault,local: Bool = false) throws -> ArchiveFileRecord {
        let path = manifest(id,local: local)
        let fd = Darwin.open(path.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MessageArchiveError.integrity }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 28, info.st_size <= 16412 else { throw MessageArchiveError.integrity }
        var data = Data(count: Int(info.st_size))
        guard data.withUnsafeMutableBytes({ Darwin.read(fd,$0.baseAddress,$0.count) }) == data.count else { throw MessageArchiveError.integrity }
        do {
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data),using: SymmetricKey(data: vault.key),authenticating: binding(id,vault,local: local))
            let record = try JSONDecoder().decode(ArchiveFileRecord.self,from: clear)
            guard record.id == id, record.storageID == (local ? localStorageID(vault) : storageID),
                  record.state == (local ? .local : .pending) else { throw MessageArchiveError.integrity }
            if local {
                guard case .some(.outgoing) = record.purpose,
                      record.objectKey == "local-preparations/\(vault.id.uuidString.lowercased())/files/\(id.uuidString.lowercased())" else { throw MessageArchiveError.integrity }
            }
            return record
        } catch { throw MessageArchiveError.integrity }
    }
    private static func syncDirectory(_ spool: URL) throws {
        let fd = Darwin.open(spool.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MessageArchiveError.integrity }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw MessageArchiveError.database }
    }

    public func capture(_ capture: ArchiveFileCapture, identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment,
                        defaultEnabled: Bool = true, reservedID: UUID? = nil) async throws -> ArchiveFileRecord {
        let local = try !conversationFileSavingEnabled(identity: identity,defaultEnabled: defaultEnabled)
        guard let record = try await self.capture(capture,identity: identity,attachment: attachment,
            purpose: .outgoing(defaultEnabled: defaultEnabled),local: local,reservedID: reservedID) else {
            throw MessageArchiveError.integrity
        }
        return record
    }

    private func capture(_ capture: ArchiveFileCapture, identity: MessageArchiveIdentity,
                         attachment: MessageArchiveAttachment, purpose: ArchiveFilePurpose,local: Bool = false,
                         reservedID: UUID? = nil) async throws -> ArchiveFileRecord? {
        var queued = false
        do {
        try ArchiveFileRecord.validateMetadata(identity: identity,attachment: attachment)
        try prepareSpool()
        let vault = try keys(), id = reservedID ?? UUID()
        guard id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else { throw MessageArchiveError.invalid }
        let receipt = try capture.seal(to: envelope(id),key: vault.key,objectID: id)
        let record = ArchiveFileRecord(id: id,identity: identity,attachment: attachment,
            objectKey: "\(local ? "local-preparations" : "vaults")/\(vault.id.uuidString.lowercased())/files/\(id.uuidString.lowercased())",
            storageID: local ? localStorageID(vault) : storageID,receipt: receipt,state: local ? .local : .pending,purpose: purpose)
        try save(record,vault: vault) { queued = true }
        if local { return record }
        return try await upload(record)
        } catch { throw ArchiveFileCaptureFailure(isQueued: queued) }
    }

    private func upload(_ record: ArchiveFileRecord,
                        legacyConversationDefault: (@Sendable (MessageArchiveIdentity) -> Bool?)? = nil) async throws -> ArchiveFileRecord? {
        switch record.purpose {
        case let .some(.conversation(defaultEnabled)), let .some(.outgoing(defaultEnabled)):
            guard try conversationFileSavingEnabled(identity: record.identity,defaultEnabled: defaultEnabled) else { return nil }
        case .none, .some(.preparation):
            guard let defaultEnabled = legacyConversationDefault?(record.identity),
                  try conversationFileSavingEnabled(identity: record.identity,defaultEnabled: defaultEnabled) else { return nil }
        }
        guard processing.insert(record.id).inserted else { throw S3ObjectStoreError.uncertain }
        defer { processing.remove(record.id) }
        do {
            _ = try open().appendFile(record)
            _ = try await storage.put(file: envelope(record.id),key: record.objectKey,sha256: record.sha256,byteCount: record.byteCount)
            var stored = record; stored.state = .stored
            _ = try open().appendFile(stored)
            // Unlink only our authenticated immutable queue item, after both commits.
            guard unlink(manifest(record.id).path) == 0 else { throw MessageArchiveError.database }
            guard unlink(envelope(record.id).path) == 0 else { throw MessageArchiveError.database }
            try directorySync(spool)
            return stored
        } catch { store = nil; throw error }
    }

    public func conversationFileSavingEnabled(identity: MessageArchiveIdentity, defaultEnabled: Bool) throws -> Bool {
        do { return try open().conversationFileSavingEnabled(identity: identity,defaultEnabled: defaultEnabled) }
        catch { store = nil; throw error }
    }
    public func setConversationFileSavingEnabled(identity: MessageArchiveIdentity, enabled: Bool) throws {
        do { try open().setConversationFileSavingEnabled(identity: identity,enabled: enabled) }
        catch { store = nil; throw error }
    }
    public func captureConversationFile(_ capture: ArchiveFileCapture, identity: MessageArchiveIdentity,
                                        attachment: MessageArchiveAttachment, defaultEnabled: Bool) async throws -> ArchiveFileRecord? {
        guard try conversationFileSavingEnabled(identity: identity,defaultEnabled: defaultEnabled) else { return nil }
        return try await self.capture(capture,identity: identity,attachment: attachment,purpose: .conversation(defaultEnabled: defaultEnabled))
    }

    @discardableResult public func resume(legacyConversationDefault: (@Sendable (MessageArchiveIdentity) -> Bool?)? = nil) async throws -> Int {
        try prepareSpool()
        let vault = try keys()
        let files = try FileManager.default.contentsOfDirectory(at: spool,includingPropertiesForKeys: nil)
        var count = 0
        var failure: Error?
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "receipt" {
            do {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { throw MessageArchiveError.integrity }
                if processing.contains(id) { continue }
                guard count < 100 else { throw S3ObjectStoreError.uncertain }
                let record = try load(id,vault: vault)
                if try await upload(record,legacyConversationDefault: legacyConversationDefault) != nil { count += 1 }
            } catch { failure = error }
        }
        if let failure { throw failure }
        return count
    }

    public func files(identity: MessageArchiveIdentity,attachmentID: String) throws -> [ArchiveFileRecord] {
        do { return try open().files(identity: identity,attachmentID: attachmentID) }
        catch { store = nil; throw error }
    }

    /// Resolve one pre-reserved outgoing capture. Local records retain their
    /// original policy; a missing/corrupt receipt never authorizes recapture.
    public func recoverOutgoingCapture(id: UUID, identity: MessageArchiveIdentity, attachmentID: String) async throws -> ArchiveFileRecord? {
        try prepareSpool()
        let vault = try keys()
        func matches(_ record: ArchiveFileRecord) -> Bool {
            guard case .some(.outgoing) = record.purpose else { return false }
            return record.id == id && record.identity == identity && record.attachment.id.utf8.elementsEqual(attachmentID.utf8)
        }
        if FileManager.default.fileExists(atPath: manifest(id,local: true).path) {
            let record = try load(id,vault: vault,local: true)
            guard matches(record) else { throw MessageArchiveError.integrity }
            return record
        }
        let pending = try FileManager.default.fileExists(atPath: manifest(id).path) ? load(id,vault: vault) : nil
        if let pending, !matches(pending) { throw MessageArchiveError.integrity }
        let records = try files(identity: identity,attachmentID: attachmentID).filter { $0.id == id }
        if let stored = records.first(where: { $0.state == .stored }) {
            guard matches(stored), records.allSatisfy({ value in
                var normalized = value; normalized.state = .stored; return normalized == stored
            }) else { throw MessageArchiveError.integrity }
            if var pending { pending.state = .stored; guard pending == stored else { throw MessageArchiveError.integrity } }
            return stored
        }
        if let pending {
            guard let stored = try await upload(pending) else { throw MessageArchiveError.integrity }
            return stored
        }
        guard records.isEmpty, !FileManager.default.fileExists(atPath: envelope(id).path) else { throw MessageArchiveError.integrity }
        return nil
    }

    public func export(_ record: ArchiveFileRecord,to destination: URL) async throws {
        let vault = try keys()
        if record.state == .local {
            try prepareSpool()
            guard try load(record.id,vault: vault,local: true) == record else { throw MessageArchiveError.integrity }
        } else {
            guard record.state == .stored else { throw MessageArchiveError.integrity }
            if record.storageID != storageID {
                guard try open().acceptsStorageAlias(source: record.storageID, destination: storageID) else { throw MessageArchiveError.integrity }
            }
            let authenticated = try open().files(identity: record.identity,attachmentID: record.attachment.id)
            guard authenticated.contains(record) else { throw MessageArchiveError.integrity }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-s3-export-\(UUID().uuidString)",isDirectory: true)
        try FileManager.default.createDirectory(at: temporary,withIntermediateDirectories: false,attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let encrypted = temporary.appendingPathComponent("encrypted")
        if record.state == .local {
            try await S3LocalFile.export(envelope(record.id),destination: encrypted,hash: record.sha256,count: record.byteCount)
        } else {
            try await storage.download(key: record.objectKey,to: encrypted,sha256: record.sha256,byteCount: record.byteCount)
        }
        let clear = temporary.appendingPathComponent("clear")
        let hash = try ArchiveFileEnvelope.open(file: encrypted,to: clear,key: vault.key,objectID: record.id,plaintextByteCount: record.plaintextByteCount)
        guard hash == record.plaintextSHA256 else { throw MessageArchiveError.integrity }
        // Exclusive destination; UI uses the existing atomic export boundary for replacement.
        try FileManager.default.copyItem(at: clear,to: destination)
    }
}
