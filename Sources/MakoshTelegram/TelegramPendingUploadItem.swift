import Foundation
import MakoshCore

/// Stable preparation identity, independent of preview position or restored tmp path.
internal struct TelegramPendingUploadItem: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let file: ArchiveFileRecord
    let video: TelegramUploadVideoMetadata?
    let videoCover: TelegramPendingUploadVideoCover?
    let originalFile: ArchiveFileRecord?

    init(id: UUID, file: ArchiveFileRecord, video: TelegramUploadVideoMetadata? = nil,
         videoCover: TelegramPendingUploadVideoCover? = nil, originalFile: ArchiveFileRecord? = nil) {
        self.id = id; self.file = file; self.video = video; self.videoCover = videoCover; self.originalFile = originalFile
    }

    static func attachmentID(_ id: UUID) -> String { "prepared:" + id.uuidString.lowercased() }
    static func coverAttachmentID(_ id: UUID) -> String { "video-cover:" + id.uuidString.lowercased() }
    static func originalAttachmentID(_ id: UUID) -> String { "original:" + id.uuidString.lowercased() }

    func isValid(identity: MessageArchiveIdentity, legacy: Bool) -> Bool {
        guard id != TelegramPendingUploadDraft.zeroUUID &&
            (file.attachment.kind == "video") == (video != nil) &&
            (video?.isValid(name: file.attachment.name, size: file.plaintextByteCount) ?? true) &&
            (videoCover == nil || video != nil) &&
            (videoCover?.isValid(identity: identity, attachmentID: legacy ? "video-cover" : Self.coverAttachmentID(id)) ?? true) &&
            Self.validRecord(file, identity: identity, attachmentID: legacy ? "prepared" : Self.attachmentID(id)) else { return false }
        guard let originalFile else { return true }
        return !legacy && file.attachment.kind == "photo" && originalFile.attachment.kind == "file" &&
            originalFile.plaintextByteCount <= 20 * 1024 * 1024 &&
            Self.validRecord(originalFile, identity: identity, attachmentID: Self.originalAttachmentID(id))
    }

    func matchesOriginal(_ staged: TelegramUploadFile?) -> Bool {
        switch (originalFile, staged) {
        case (nil, nil): return true
        case let (.some(record), .some(file)):
            return file.mode == .file && file.video == nil && file.videoCover == nil &&
                record.attachment.name.utf8.elementsEqual(file.name.utf8) && record.plaintextByteCount == file.size &&
                (try? TelegramUploadFileIO.validateOwnedStage(file)) != nil
        default: return false
        }
    }

    private static func validRecord(_ file: ArchiveFileRecord, identity: MessageArchiveIdentity, attachmentID: String) -> Bool {
        file.state == .stored && file.id != TelegramPendingUploadDraft.zeroUUID && file.identity == identity &&
            file.attachment.id == attachmentID &&
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

public struct TelegramUploadBatchItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let file: TelegramUploadFile
    public let originalFile: TelegramUploadFile?
    public init(id: UUID, file: TelegramUploadFile, originalFile: TelegramUploadFile? = nil) {
        self.id = id; self.file = file; self.originalFile = originalFile
    }
    func discard(using discard: (TelegramUploadFile) throws -> Void = TelegramUploadFileIO.discard) throws {
        var failure: (any Error)?
        for file in [file] + (originalFile.map { [$0] } ?? []) {
            do { try discard(file) } catch { failure = error }
        }
        if let failure { throw failure }
    }
}

public struct TelegramUploadSelection: Equatable, Sendable {
    public let source: URL
    public let mode: TelegramUploadMode
    public init(source: URL, mode: TelegramUploadMode) { self.source = source; self.mode = mode }
}
