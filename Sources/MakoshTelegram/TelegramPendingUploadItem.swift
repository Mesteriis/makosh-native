import Foundation
import MakoshCore

/// Stable preparation identity, independent of preview position or restored tmp path.
internal struct TelegramPendingUploadItem: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let file: ArchiveFileRecord
    let video: TelegramUploadVideoMetadata?
    let videoCover: TelegramPendingUploadVideoCover?

    static func attachmentID(_ id: UUID) -> String { "prepared:" + id.uuidString.lowercased() }
    static func coverAttachmentID(_ id: UUID) -> String { "video-cover:" + id.uuidString.lowercased() }

    func isValid(identity: MessageArchiveIdentity, legacy: Bool) -> Bool {
        id != TelegramPendingUploadDraft.zeroUUID &&
            (file.attachment.kind == "video") == (video != nil) &&
            (video?.isValid(name: file.attachment.name, size: file.plaintextByteCount) ?? true) &&
            (videoCover == nil || video != nil) &&
            (videoCover?.isValid(identity: identity, attachmentID: legacy ? "video-cover" : Self.coverAttachmentID(id)) ?? true) &&
            file.state == .stored && file.id != TelegramPendingUploadDraft.zeroUUID && file.identity == identity &&
            file.attachment.id == (legacy ? "prepared" : Self.attachmentID(id)) &&
            ["file", "photo", "video"].contains(file.attachment.kind) &&
            !file.attachment.name.isEmpty && file.attachment.name.utf8.count <= 1024 &&
            !file.attachment.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            !file.attachment.name.contains("/") && !file.attachment.name.contains("\\") &&
            file.attachment.name != "." && file.attachment.name != ".." &&
            file.plaintextByteCount >= 0 && file.plaintextByteCount <= 4 * 1024 * 1024 * 1024 &&
            file.attachment.size == file.plaintextByteCount &&
            file.byteCount > 0 && file.byteCount <= 4 * 1024 * 1024 * 1024 + 1024 * 1024 &&
            TelegramPendingUploadDraft.isHash(file.sha256) && TelegramPendingUploadDraft.isHash(file.plaintextSHA256) &&
            TelegramPendingUploadDraft.isHash(file.storageID) && TelegramPendingUploadDraft.isObjectKey(file.objectKey) &&
            file.capturedAt.timeIntervalSince1970.isFinite
    }
}

internal struct TelegramUploadBatchItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let file: TelegramUploadFile
}
