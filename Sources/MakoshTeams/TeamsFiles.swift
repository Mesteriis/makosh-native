import Foundation
import Darwin
import CryptoKit
import MakoshCore

public struct TeamsPreparedFile: Codable, Identifiable, Sendable {
    public let id: UUID
    public let scope: TeamsScope
    public let name: String
    public let size: Int64
    public let sha256: String
    public var archiveReceipt: ArchiveFileRecord?
}

/// Plaintext is an explicitly owned, short-lived preview/send/export lease, never a persistence payload.
public final class TeamsFileLease: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var released = false
    private let directory: URL
    init(url: URL, directory: URL) { self.url = url; self.directory = directory }
    static func destination(suffix: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-teams-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let safe = suffix.utf8.count <= 12 && suffix.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        return (root, root.appendingPathComponent("file" + (safe && !suffix.isEmpty ? "." + suffix : "")))
    }
    public func release() async {
        let remove = lock.withLock { if released { return false }; released = true; return true }
        if remove {
            let directory = directory
            let removed = await Task.detached(priority: .utility) { () -> Bool in
                do { try FileManager.default.removeItem(at: directory); return true } catch { return false }
            }.value
            if !removed { lock.withLock { released = false } }
        }
    }
    deinit {
        let remove = lock.withLock { !released }
        if remove { let directory = directory; Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) } }
    }
}

actor TeamsFiles {
    private let configuration: ContactWorkspaceConfiguration
    let repository: TeamsRepository
    private let storage: S3ObjectStoreConfiguration
    private let spoolDirectory: URL
    private let keyProvider: @Sendable (UUID, Bool) throws -> Data
    private var files: ArchiveFileRepository?
    var processingIncoming = Set<UUID>()
    init(configuration: ContactWorkspaceConfiguration, repository: TeamsRepository, storage: S3ObjectStoreConfiguration,
         spoolDirectory: URL, keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data) {
        self.configuration = configuration; self.repository = repository; self.storage = storage
        self.spoolDirectory = spoolDirectory; self.keyProvider = keyProvider
    }
    func archive() throws -> ArchiveFileRepository {
        if let files { return files }
        let value = try ArchiveFileRepository(connectionString: configuration.connectionString,
            schema: configuration.archiveSchema ?? configuration.schema, configuration: storage,
            spoolDirectory: spoolDirectory, keyProvider: keyProvider)
        files = value; return value
    }
    func policyIdentity(_ scope: TeamsScope, messageID: String) -> MessageArchiveIdentity {
        scope.policyScope.archiveIdentity(messageID: messageID)
    }
    func defaultEnabled(_ scope: TeamsScope) async throws -> Bool {
        _ = try await repository.validate(scope)
        guard case .chat = scope.resource else { return false }
        return try await repository.conversations(accountID: scope.accountID).first { $0.scope == scope }?.kind == .oneOnOne
    }
    func savingFiles(scope: TeamsScope) async throws -> Bool {
        let enabled = try await defaultEnabled(scope)
        return try await archive().conversationFileSavingEnabled(identity: policyIdentity(scope, messageID: "policy"), defaultEnabled: enabled)
    }
    func setSavingFiles(scope: TeamsScope, enabled: Bool) async throws {
        _ = try await repository.validate(scope)
        try await archive().setConversationFileSavingEnabled(identity: policyIdentity(scope, messageID: "policy"), enabled: enabled)
    }
    func prepare(scope: TeamsScope, files urls: [URL]) async throws -> [TeamsPreparedFile] {
        guard (1...10).contains(urls.count) else { throw TeamsFailure.invalidResource }
        let account = try await repository.validate(scope)
        guard !account.readOnly else { throw TeamsFailure.forbidden }
        let defaultSaving = try await defaultEnabled(scope)
        var captures: [ArchiveFileCapture] = []
        var values: [TeamsPreparedFile] = []
        // Validate/freeze the entire batch before any archive capture or S3 admission.
        for url in urls {
            try Task.checkCancellation()
            guard url.isFileURL, !url.path.utf8.contains(0), !url.lastPathComponent.isEmpty, url.lastPathComponent.utf8.count <= 1024 else { throw TeamsFailure.invalidResource }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 100 * 1024 * 1024 else { throw TeamsFailure.invalidResource }
            let capture: ArchiveFileCapture
            do { capture = try ArchiveFileCapture(file: url, byteCount: Int64(info.st_size)) } catch { throw TeamsFailure.invalidResource }
            captures.append(capture)
            values.append(TeamsPreparedFile(id: UUID(), scope: scope, name: url.lastPathComponent, size: Int64(info.st_size), sha256: try capture.plaintextSHA256(), archiveReceipt: nil))
        }
        try await repository.reservePreparedFiles(values)
        for index in values.indices {
            try Task.checkCancellation()
            let value = values[index]
            let identity = policyIdentity(scope, messageID: "preparation:" + value.id.uuidString)
            let attachment = MessageArchiveAttachment(id: value.id.uuidString, kind: "file", name: value.name, size: value.size)
            let receipt = try await archive().capture(captures[index], identity: identity, attachment: attachment,
                defaultEnabled: defaultSaving, reservedID: value.id)
            guard receipt.plaintextSHA256 == value.sha256, receipt.plaintextByteCount == value.size else { throw TeamsFailure.storage }
            values[index].archiveReceipt = receipt
            try await repository.savePreparedReceipt(values[index])
        }
        return values
    }
    func prepared(scope: TeamsScope, ids: [UUID]) async throws -> [TeamsPreparedFile] {
        var values = try await repository.preparedFiles(scope: scope, ids: ids)
        for index in values.indices where values[index].archiveReceipt == nil {
            let value = values[index]
            guard let record = try await archive().recoverOutgoingCapture(id: value.id,
                identity: policyIdentity(scope, messageID: "preparation:" + value.id.uuidString), attachmentID: value.id.uuidString, uploadPending: false),
                record.plaintextSHA256 == value.sha256, record.plaintextByteCount == value.size else { throw TeamsFailure.storage }
            values[index].archiveReceipt = record
            try await repository.savePreparedReceipt(values[index])
        }
        return values
    }
    func openPrepared(scope: TeamsScope, id: UUID) async throws -> TeamsFileLease {
        guard let value = try await prepared(scope: scope, ids: [id]).first, let receipt = value.archiveReceipt else { throw TeamsFailure.invalidResource }
        let (directory, destination) = try leaseDestination(extension: URL(fileURLWithPath: value.name).pathExtension)
        do {
            try await archive().export(receipt, to: destination)
            return TeamsFileLease(url: destination, directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func leaseDestination(extension suffix: String) throws -> (URL, URL) {
        try TeamsFileLease.destination(suffix: suffix)
    }
}

extension TeamsRepository {
    func reservePreparedFiles(_ values: [TeamsPreparedFile]) throws {
        guard (1...10).contains(values.count), Set(values.map(\.id)).count == values.count else { throw TeamsFailure.invalidResource }
        let db = try db()
        try db.transaction {
            for value in values {
                _ = try validate(value.scope)
                guard value.archiveReceipt == nil, value.size >= 0, value.size <= 100 * 1024 * 1024 else { throw TeamsFailure.invalidResource }
                let token = try db.token(["prepared-file", value.scope.accountID.uuidString, value.id.uuidString])
                _ = try db.query("INSERT INTO \(db.prefix)teams_prepared_files VALUES($1,$2,$3)", [token, try db.token(value.scope.storageKey), try db.seal(value, token: "prepared-file:" + token)])
            }
        }
    }
    func preparedFiles(scope: TeamsScope, ids: [UUID]) throws -> [TeamsPreparedFile] {
        _ = try validate(scope)
        guard ids.count <= 10, Set(ids).count == ids.count else { throw TeamsFailure.invalidResource }
        let db = try db()
        return try ids.map { id in
            let token = try db.token(["prepared-file", scope.accountID.uuidString, id.uuidString])
            guard let row = try db.query("SELECT ciphertext FROM \(db.prefix)teams_prepared_files WHERE token=$1 AND scope=$2", [token, try db.token(scope.storageKey)]).first else { throw TeamsFailure.invalidResource }
            let value: TeamsPreparedFile = try db.decode(row[0], token: "prepared-file:" + token)
            guard value.id == id, value.scope == scope else { throw TeamsFailure.storage }; return value
        }
    }
    func savePreparedReceipt(_ value: TeamsPreparedFile) throws {
        let db = try db()
        try db.transaction {
            let prior = try preparedFiles(scope: value.scope, ids: [value.id])[0]
            guard prior.name == value.name, prior.size == value.size, prior.sha256 == value.sha256,
                  let receipt = value.archiveReceipt, receipt.id == value.id,
                  receipt.plaintextSHA256 == value.sha256, receipt.plaintextByteCount == value.size,
                  prior.archiveReceipt == nil || prior.archiveReceipt == receipt else { throw TeamsFailure.storage }
            let token = try db.token(["prepared-file", value.scope.accountID.uuidString, value.id.uuidString])
            _ = try db.query("UPDATE \(db.prefix)teams_prepared_files SET ciphertext=$2 WHERE token=$1", [token, try db.seal(value, token: "prepared-file:" + token)])
        }
    }
}
