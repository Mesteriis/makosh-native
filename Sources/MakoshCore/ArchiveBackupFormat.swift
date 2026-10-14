import Foundation
import CryptoKit

struct ArchiveBackupHeader: Codable {
    let vaultID: UUID, rootKey: Data
    let partCount: Int, databaseBytes: Int64, databaseHash: String
    let counts: [String: Int64]
    let objectCount: Int, objectBytes: Int64
    let sourceStorageID: String?
    var summary: ArchiveBackupSummary {
        .init(vaultID: vaultID, messageVersions: counts[ArchiveBackupTable.events.rawValue] ?? 0, files: objectCount, encryptedBytes: objectBytes, databaseBytes: databaseBytes)
    }
    func validate() throws {
        guard rootKey.count == 32, (1...ArchiveBackupLimits.parts).contains(partCount),
              databaseBytes > 0, databaseBytes <= Int64(ArchiveBackupLimits.part) * Int64(ArchiveBackupLimits.parts),
              partCount == Int((databaseBytes + Int64(ArchiveBackupLimits.part) - 1) / Int64(ArchiveBackupLimits.part)),
              ArchiveBackupCryptography.validHash(databaseHash),
              Set(counts.keys) == Set(ArchiveBackupTable.allCases.map(\.rawValue)), counts.values.allSatisfy({ (0...Int64(ArchiveBackupLimits.rows)).contains($0) }),
              counts.values.reduce(Int64(0), +) <= ArchiveBackupLimits.rows, counts[ArchiveBackupTable.metadata.rawValue] == 1,
              (0...ArchiveBackupLimits.objects).contains(objectCount), objectBytes >= 0,
              objectBytes <= Int64(objectCount) * (4 * 1024 * 1024 * 1024 + 1024 * 1024),
              sourceStorageID.map(ArchiveBackupCryptography.validHash) ?? (objectCount == 0) else { throw ArchiveBackupError.invalid }
    }
}
private struct ArchiveBackupHeaderEnvelope: Codable {
    let format: String, version: Int, backupID: UUID, payload: Data
}
private struct ArchiveBackupRecovery: Codable {
    let format: String, version: Int, backupID: UUID, key: Data
}

enum ArchiveBackupFormat {
    static func partName(_ index: Int) -> String { String(format: "%08d.part", index) }
    static func objectName(_ id: UUID) -> String { id.uuidString.lowercased() + ".envelope" }
    static func key(_ recovery: Data, id: UUID, scope: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recovery), salt: Data(id.uuidString.utf8), info: Data("makosh-portable-\(scope)-v1".utf8), outputByteCount: 32)
    }
    static func partKey(_ recovery: Data, id: UUID, index: Int) -> Data {
        key(recovery, id: id, scope: "database-\(index)").withUnsafeBytes { Data($0) }
    }
    static func recoveryData(_ recovery: Data, id: UUID) throws -> Data {
        try ArchiveBackupCryptography.encode(ArchiveBackupRecovery(format: "MAKOSH-RECOVERY", version: 1, backupID: id, key: recovery))
    }
    static func headerData(_ header: ArchiveBackupHeader, recovery: Data, id: UUID) throws -> Data {
        try header.validate()
        let aad = Data("MAKOSH-ARCHIVE|1|\(id.uuidString)".utf8)
        guard let sealed = try AES.GCM.seal(ArchiveBackupCryptography.encode(header), using: key(recovery, id: id, scope: "header"), authenticating: aad).combined else { throw ArchiveBackupError.integrity }
        return try ArchiveBackupCryptography.encode(ArchiveBackupHeaderEnvelope(format: "MAKOSH-ARCHIVE", version: 1, backupID: id, payload: sealed))
    }
    static func readHeader(_ package: ArchiveBackupDirectory, recoveryKey: URL) throws -> (UUID, Data, ArchiveBackupHeader, String) {
        let bytes = try package.file("header.json").boundedData(maximum: 65_536)
        let envelope = try JSONDecoder().decode(ArchiveBackupHeaderEnvelope.self, from: bytes)
        guard envelope.format == "MAKOSH-ARCHIVE", envelope.version == 1, envelope.payload.count <= 49_152 else { throw ArchiveBackupError.unsupported }
        let parent = try ArchiveBackupDirectory(recoveryKey.deletingLastPathComponent())
        let recovery = try JSONDecoder().decode(ArchiveBackupRecovery.self, from: parent.file(recoveryKey.lastPathComponent).boundedData(maximum: 1024))
        guard recovery.format == "MAKOSH-RECOVERY", recovery.version == 1, recovery.backupID == envelope.backupID, recovery.key.count == 32 else { throw ArchiveBackupError.keyUnavailable }
        let aad = Data("MAKOSH-ARCHIVE|1|\(envelope.backupID.uuidString)".utf8)
        let clear: Data
        do { clear = try AES.GCM.open(.init(combined: envelope.payload), using: key(recovery.key, id: envelope.backupID, scope: "header"), authenticating: aad) }
        catch { throw ArchiveBackupError.integrity }
        let header = try JSONDecoder().decode(ArchiveBackupHeader.self, from: clear)
        try header.validate()
        return (envelope.backupID, recovery.key, header, ArchiveBackupCryptography.hash(bytes))
    }
    static func verifyObject(_ record: ArchiveFileRecord, encrypted: URL, workspace: ArchiveBackupDirectory, crypto: ArchiveBackupCryptography) throws {
        let clear = workspace.url.appendingPathComponent("verify-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: clear) }
        let hash = try ArchiveFileEnvelope.open(file: encrypted, to: clear, key: crypto.fileKey, objectID: record.id, plaintextByteCount: record.plaintextByteCount)
        guard hash == record.plaintextSHA256 else { throw ArchiveBackupError.integrity }
    }
}

final class ArchiveBackupPartWriter {
    private let directory: ArchiveBackupDirectory, workspace: ArchiveBackupDirectory
    private let recovery: Data, id: UUID
    private var file: ArchiveBackupFile?, partBytes = 0, hash = SHA256()
    private(set) var totalBytes: Int64 = 0, partCount = 0
    init(directory: ArchiveBackupDirectory, workspace: ArchiveBackupDirectory, recovery: Data, id: UUID) {
        self.directory = directory; self.workspace = workspace; self.recovery = recovery; self.id = id
    }
    func write(_ data: Data) throws {
        hash.update(data: data)
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard partCount < ArchiveBackupLimits.parts else { throw ArchiveBackupError.invalid }
            if file == nil { file = try workspace.file("plain-\(partCount)", create: true) }
            let count = min(data.count - offset, ArchiveBackupLimits.part - partBytes)
            try file?.write(data.subdata(in: offset..<(offset + count)))
            offset += count; partBytes += count; totalBytes += Int64(count)
            if partBytes == ArchiveBackupLimits.part { try flush() }
        }
    }
    private func flush() throws {
        guard partBytes > 0, let file else { return }
        try file.sync()
        let clear = workspace.url.appendingPathComponent("plain-\(partCount)")
        _ = try ArchiveFileCapture(file: clear, byteCount: Int64(partBytes)).seal(to: directory.url.appendingPathComponent(ArchiveBackupFormat.partName(partCount)),
            key: ArchiveBackupFormat.partKey(recovery, id: id, index: partCount), objectID: id)
        self.file = nil; try FileManager.default.removeItem(at: clear); partCount += 1; partBytes = 0
    }
    func finish() throws -> String {
        try flush(); try directory.sync()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class ArchiveBackupVerified {
    let workspace: ArchiveBackupWorkspace, header: ArchiveBackupHeader
    let objects: [ArchiveBackupObject], aliases: Set<String>
    let database: ArchiveBackupFile
    let fingerprint: String
    var objectDirectory: URL { workspace.directory.url.appendingPathComponent("objects", isDirectory: true) }
    init(workspace: ArchiveBackupWorkspace, header: ArchiveBackupHeader, objects: [ArchiveBackupObject], aliases: Set<String>, database: ArchiveBackupFile, fingerprint: String) {
        self.workspace = workspace; self.header = header; self.objects = objects; self.aliases = aliases; self.database = database
        self.fingerprint = fingerprint
    }
    static func open(package: URL, recoveryKey: URL) throws -> ArchiveBackupVerified {
        let input = try ArchiveBackupDirectory(package)
        guard try input.names() == Set(["header.json", "database", "objects"]) else { throw ArchiveBackupError.invalid }
        let (id, recovery, header, fingerprint) = try ArchiveBackupFormat.readHeader(input, recoveryKey: recoveryKey)
        let workspace = try ArchiveBackupWorkspace(), root = workspace.directory
        let encryptedParts = try input.directory("database"), inputObjects = try input.directory("objects")
        guard try encryptedParts.names() == Set((0..<header.partCount).map(ArchiveBackupFormat.partName)) else { throw ArchiveBackupError.incomplete }
        let destination = try root.file("database.records", create: true)
        var databaseHash = SHA256(), remaining = header.databaseBytes
        for index in 0..<header.partCount {
            try Task.checkCancellation()
            let size = min(remaining, Int64(ArchiveBackupLimits.part))
            let encryptedName = "cipher-\(index)", clearName = "clear-\(index)"
            let source = try encryptedParts.file(ArchiveBackupFormat.partName(index))
            guard source.byteCount > size, source.byteCount <= size + 1024 * 1024 else { throw ArchiveBackupError.invalid }
            try source.copy(to: root.file(encryptedName, create: true), expectedCount: source.byteCount)
            _ = try ArchiveFileEnvelope.open(file: root.url.appendingPathComponent(encryptedName), to: root.url.appendingPathComponent(clearName),
                key: ArchiveBackupFormat.partKey(recovery, id: id, index: index), objectID: id, plaintextByteCount: size)
            let clear = try root.file(clearName)
            var partRemaining = size
            while partRemaining > 0 {
                let bytes = try clear.readExactly(Int(min(partRemaining, 1024 * 1024)))
                databaseHash.update(data: bytes); try destination.write(bytes); partRemaining -= Int64(bytes.count)
            }
            try clear.stable()
            try FileManager.default.removeItem(at: root.url.appendingPathComponent(encryptedName))
            try FileManager.default.removeItem(at: root.url.appendingPathComponent(clearName))
            remaining -= size
        }
        try destination.sync()
        let digest = databaseHash.finalize().map { String(format: "%02x", $0) }.joined()
        guard remaining == 0, digest == header.databaseHash else { throw ArchiveBackupError.integrity }
        let database = try root.file("database.records"), reader = try ArchiveBackupRecordReader(database)
        let validator = try ArchiveBackupRowValidator(vaultID: header.vaultID, rootKey: header.rootKey)
        while let row = try reader.next() { try Task.checkCancellation(); try validator.accept(row) }
        let objects = try validator.finish()
        guard validator.counts == header.counts, objects.count == header.objectCount,
              objects.reduce(Int64(0), { $0 + $1.record.byteCount }) == header.objectBytes,
              try inputObjects.names() == Set(objects.map { ArchiveBackupFormat.objectName($0.record.id) }) else { throw ArchiveBackupError.incomplete }
        let outputObjects = try root.createDirectory("objects")
        for object in objects {
            try Task.checkCancellation()
            let record = object.record, name = ArchiveBackupFormat.objectName(record.id)
            try inputObjects.file(name).copy(to: outputObjects.file(name, create: true), expectedCount: record.byteCount, expectedHash: record.sha256)
            try ArchiveBackupFormat.verifyObject(record, encrypted: outputObjects.url.appendingPathComponent(name), workspace: root, crypto: validator.crypto)
        }
        guard try input.names() == Set(["header.json", "database", "objects"]),
              try encryptedParts.names() == Set((0..<header.partCount).map(ArchiveBackupFormat.partName)),
              try inputObjects.names() == Set(objects.map { ArchiveBackupFormat.objectName($0.record.id) }) else { throw ArchiveBackupError.integrity }
        return .init(workspace: workspace, header: header, objects: objects, aliases: validator.aliases, database: database, fingerprint: fingerprint)
    }
}
