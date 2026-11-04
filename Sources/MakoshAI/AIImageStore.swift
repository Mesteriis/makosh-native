import CryptoKit
import Foundation
import MakoshCore

/// Generated images are sealed with the archive envelope format under a
/// random per-image key and kept in S3 under `ai/<conversation>/<object>`, or
/// in a local directory when the S3 policy is off or no S3 store is
/// configured. The bucket denies DeleteObject (docs/object-storage.md), so
/// deleting an S3 image means forgetting its key; local files are removed.
public actor AIImageStore {
    private let s3: S3ObjectStore?
    private let localDirectory: URL

    public init(s3: S3ObjectStore?, localDirectory: URL) {
        self.s3 = s3
        self.localDirectory = localDirectory
    }

    public func store(_ png: Data, conversationID: UUID, toS3: Bool) async throws -> AIImageReference {
        let objectID = UUID()
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let plain = work.appendingPathComponent("plain"), sealed = work.appendingPathComponent("sealed")
        try png.write(to: plain)
        let receipt: ArchiveFileEnvelopeReceipt
        do {
            receipt = try ArchiveFileCapture(file: plain, byteCount: Int64(png.count)).seal(to: sealed, key: key, objectID: objectID)
        } catch {
            throw AIFailure.storage
        }
        if toS3, let s3 {
            do {
                _ = try await s3.put(
                    file: sealed, key: Self.objectKey(conversationID, objectID), sha256: receipt.sha256, byteCount: receipt.byteCount)
            } catch { throw AIFailure.storage }
        } else {
            do {
                try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: sealed, to: localFile(objectID))
            } catch { throw AIFailure.storage }
        }
        return AIImageReference(
            objectID: objectID, byteCount: receipt.byteCount, sha256: receipt.sha256, plaintextByteCount: receipt.plaintextByteCount,
            key: key, inS3: toS3 && s3 != nil)
    }

    public func load(_ reference: AIImageReference, conversationID: UUID) async throws -> Data {
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        var sealed = localFile(reference.objectID)
        if reference.inS3 {
            guard let s3 else { throw AIFailure.storage }
            sealed = work.appendingPathComponent("sealed")
            do {
                try await s3.download(
                    key: Self.objectKey(conversationID, reference.objectID), to: sealed, sha256: reference.sha256,
                    byteCount: reference.byteCount)
            } catch { throw AIFailure.storage }
        }
        let plain = work.appendingPathComponent("plain")
        do {
            _ = try ArchiveFileEnvelope.open(
                file: sealed, to: plain, key: reference.key, objectID: reference.objectID, plaintextByteCount: reference.plaintextByteCount)
            return try Data(contentsOf: plain)
        } catch { throw AIFailure.storage }
    }

    public func delete(_ reference: AIImageReference, conversationID: UUID) async throws {
        guard !reference.inS3 else { return }
        let file = localFile(reference.objectID)
        if FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) } catch { throw AIFailure.storage }
        }
    }

    private static func objectKey(_ conversationID: UUID, _ objectID: UUID) -> String {
        "ai/\(conversationID.uuidString.lowercased())/\(objectID.uuidString.lowercased())"
    }
    private func localFile(_ objectID: UUID) -> URL { localDirectory.appendingPathComponent(objectID.uuidString.lowercased()) }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-ai-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) } catch { throw AIFailure.storage }
        return url
    }
}
