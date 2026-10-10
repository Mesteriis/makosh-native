import Foundation

public struct ArchiveFileVault: Sendable {
    public let id: UUID
    public let key: Data
}

/// Only encrypted metadata goes to PostgreSQL; payload bytes belong in S3.
public struct ArchiveFileRecord: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, stored }
    public let id: UUID
    public let identity: MessageArchiveIdentity
    public let attachment: MessageArchiveAttachment
    public let objectKey: String
    public let storageID: String
    public let byteCount: Int64
    public let sha256: String
    public let plaintextByteCount: Int64
    public let plaintextSHA256: String
    public let capturedAt: Date
    public var state: State

    public init(id: UUID, identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment,
                objectKey: String, storageID: String, receipt: ArchiveFileEnvelopeReceipt,
                capturedAt: Date = Date(), state: State = .pending) {
        self.id = id; self.identity = identity; self.attachment = attachment
        self.objectKey = objectKey; self.storageID = storageID
        self.byteCount = receipt.byteCount; self.sha256 = receipt.sha256
        self.plaintextByteCount = receipt.plaintextByteCount; self.plaintextSHA256 = receipt.plaintextSHA256
        self.capturedAt = capturedAt; self.state = state
    }
}
