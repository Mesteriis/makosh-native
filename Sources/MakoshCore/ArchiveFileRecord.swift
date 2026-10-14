import Foundation

public enum ArchiveFilePurpose: Codable, Equatable, Sendable {
    case conversation(defaultEnabled: Bool)
    case outgoing(defaultEnabled: Bool)
    // Older receipts need the caller's service-specific conversation resolver.
    case preparation
}

public struct ArchiveFileVault: Sendable {
    public let id: UUID
    public let key: Data
}

/// Only encrypted metadata goes to PostgreSQL. Disabled outgoing preparation
/// retains an encrypted local payload and never joins the S3 retry queue.
public struct ArchiveFileRecord: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, stored, local }
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
    public let purpose: ArchiveFilePurpose?

    static func validateMetadata(identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment) throws {
        guard [identity.service,identity.accountID,identity.conversationID,identity.messageID,attachment.id]
            .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              attachment.name.utf8.count <= 1024, attachment.kind.utf8.count <= 64 else { throw MessageArchiveError.invalid }
    }
    func validate(vaultID: UUID) throws {
        try Self.validateMetadata(identity: identity, attachment: attachment)
        guard capturedAt.timeIntervalSince1970.isFinite,
              plaintextByteCount >= 0, plaintextByteCount <= 4 * 1024 * 1024 * 1024,
              byteCount > plaintextByteCount, byteCount <= 4 * 1024 * 1024 * 1024 + 1024 * 1024,
              [sha256, plaintextSHA256, storageID].allSatisfy(Self.validHash),
              objectKey == "vaults/\(vaultID.uuidString.lowercased())/files/\(id.uuidString.lowercased())" else { throw MessageArchiveError.invalid }
    }
    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public init(id: UUID, identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment,
                objectKey: String, storageID: String, receipt: ArchiveFileEnvelopeReceipt,
                capturedAt: Date = Date(), state: State = .pending, purpose: ArchiveFilePurpose? = nil) {
        self.id = id; self.identity = identity; self.attachment = attachment
        self.objectKey = objectKey; self.storageID = storageID
        self.byteCount = receipt.byteCount; self.sha256 = receipt.sha256
        self.plaintextByteCount = receipt.plaintextByteCount; self.plaintextSHA256 = receipt.plaintextSHA256
        self.capturedAt = capturedAt; self.state = state
        self.purpose = purpose
    }
}
