import Foundation
import CryptoKit

protocol ArchiveBackupObjectStorage: Sendable {
    var storageID: String { get }
    func head(key: String) async throws -> S3ObjectReceipt?
    func download(key: String, to destination: URL, sha256: String, byteCount: Int64) async throws
    func put(file: URL, key: String, sha256: String, byteCount: Int64) async throws -> S3ObjectReceipt
}
struct ArchiveBackupS3Storage: ArchiveBackupObjectStorage {
    let storageID: String
    private let storage: S3ObjectStore
    init(_ configuration: S3ObjectStoreConfiguration) throws {
        storage = try .init(configuration: configuration)
        storageID = ArchiveBackupCryptography.hash(Data((configuration.endpoint + "\0" + configuration.region + "\0" + configuration.bucket).utf8))
    }
    func head(key: String) async throws -> S3ObjectReceipt? { try await storage.head(key: key) }
    func download(key: String, to destination: URL, sha256: String, byteCount: Int64) async throws {
        try await storage.download(key: key, to: destination, sha256: sha256, byteCount: byteCount)
    }
    func put(file: URL, key: String, sha256: String, byteCount: Int64) async throws -> S3ObjectReceipt {
        try await storage.put(file: file, key: key, sha256: sha256, byteCount: byteCount)
    }
}
