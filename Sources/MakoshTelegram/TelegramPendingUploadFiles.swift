import Foundation
import Darwin
import MakoshCore

/// Pending composer media is distinct from received-message archive resources.
actor TelegramPendingUploadFiles {
    private let repository: ArchiveFileRepository
    init(repository: ArchiveFileRepository) { self.repository = repository }

    static func captureCover(_ cover: TelegramUploadVideoCover) throws -> ArchiveFileCapture {
        _ = try TelegramUploadVideoCoverIO.validatedBytes(cover)
        guard cover.name == telegramAttachmentName(cover.name) else { throw TelegramUploadFileError.unavailable }
        return try ArchiveFileCapture(file: cover.url, byteCount: cover.size)
    }

    func saveCover(_ cover: TelegramUploadVideoCover, accountID: Int64, chatID: Int64, preparationID: UUID,
                   itemID: UUID? = nil, capture: ArchiveFileCapture? = nil) async throws -> TelegramPendingUploadVideoCover {
        let frozen = try capture ?? Self.captureCover(cover)
        let record = try await repository.capture(frozen,
            identity: TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID),
            attachment: MessageArchiveAttachment(id: itemID.map(TelegramPendingUploadItem.coverAttachmentID) ?? "video-cover", kind: "photo", name: cover.name, size: cover.size))
        guard record.plaintextSHA256 == cover.sha256, record.plaintextByteCount == cover.size else {
            throw TelegramUploadFileError.unavailable
        }
        return TelegramPendingUploadVideoCover(file: record, width: cover.width, height: cover.height)
    }

    func restoreCover(_ cover: TelegramPendingUploadVideoCover, accountID: Int64, chatID: Int64, preparationID: UUID, itemID: UUID? = nil) async throws -> TelegramUploadVideoCover {
        let attachmentID = itemID.map(TelegramPendingUploadItem.coverAttachmentID) ?? "video-cover"
        guard cover.isValid(identity: TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID), attachmentID: attachmentID) else {
            throw TelegramUploadFileError.unavailable
        }
        let file = try await restorePayload(record: cover.file, accountID: accountID, chatID: chatID,
            preparationID: preparationID, video: nil, attachmentID: attachmentID)
        do {
            let restored = TelegramUploadVideoCover(id: file.id, width: cover.width, height: cover.height, size: file.size,
                name: file.name, url: file.url, directory: file.directory, sha256: cover.file.plaintextSHA256)
            _ = try TelegramUploadVideoCoverIO.validatedBytes(restored)
            return restored
        } catch {
            try? TelegramUploadFileIO.discard(file)
            throw error
        }
    }

    static func captureFile(_ file: TelegramUploadFile) throws -> ArchiveFileCapture {
        try TelegramUploadFileIO.validateOwnedStage(file)
        guard file.name == telegramAttachmentName(file.name) else { throw TelegramUploadFileError.unavailable }
        guard file.mode == .video || (file.video == nil && file.videoCover == nil) else { throw TelegramUploadFileError.unavailable }
        return try ArchiveFileCapture(file: file.url, byteCount: file.size)
    }

    func matches(file: TelegramUploadFile, record: ArchiveFileRecord) throws -> Bool {
        let capture = try Self.captureFile(file)
        if let cover = file.videoCover { _ = try Self.captureCover(cover) }
        return try capture.plaintextSHA256() == record.plaintextSHA256
    }

    func save(file: TelegramUploadFile, accountID: Int64, chatID: Int64, preparationID: UUID,
              itemID: UUID? = nil, capture frozen: ArchiveFileCapture? = nil) async throws -> ArchiveFileRecord {
        try Task.checkCancellation()
        // A batch freezes every owned inode before starting the first upload.
        let capture = try frozen ?? Self.captureFile(file)
        if file.mode != .file {
            let verified = try await TelegramUploadFileIO.restoredStage(id: file.id, name: file.name, size: file.size,
                mode: file.mode, url: file.url, directory: file.directory, video: file.video)
            guard verified.pixelWidth == file.pixelWidth, verified.pixelHeight == file.pixelHeight,
                  verified.video == file.video else {
                throw file.mode == .video ? TelegramUploadFileError.invalidVideo : .invalidImage
            }
        }
        try Task.checkCancellation()
        return try await repository.capture(capture,
            identity: TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID),
            attachment: MessageArchiveAttachment(id: itemID.map(TelegramPendingUploadItem.attachmentID) ?? "prepared", kind: file.mode.rawValue, name: file.name, size: file.size))
    }

    func restore(record: ArchiveFileRecord, accountID: Int64, chatID: Int64, preparationID: UUID, video: TelegramUploadVideoMetadata? = nil, itemID: UUID? = nil) async throws -> TelegramUploadFile {
        try await restorePayload(record: record, accountID: accountID, chatID: chatID,
            preparationID: preparationID, video: video, attachmentID: itemID.map(TelegramPendingUploadItem.attachmentID) ?? "prepared")
    }

    func saveOriginal(_ file: TelegramUploadFile, accountID: Int64, chatID: Int64, preparationID: UUID,
                      itemID: UUID, capture: ArchiveFileCapture) async throws -> ArchiveFileRecord {
        guard file.mode == .file, file.size <= 20 * 1024 * 1024 else { throw TelegramUploadFileError.unavailable }
        try Task.checkCancellation()
        return try await repository.capture(capture,
            identity: TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID),
            attachment: .init(id: TelegramPendingUploadItem.originalAttachmentID(itemID), kind: "file", name: file.name, size: file.size))
    }

    func restoreOriginal(_ record: ArchiveFileRecord, accountID: Int64, chatID: Int64, preparationID: UUID, itemID: UUID) async throws -> TelegramUploadFile {
        guard record.attachment.kind == "file", record.plaintextByteCount <= 20 * 1024 * 1024 else { throw TelegramUploadFileError.unavailable }
        return try await restorePayload(record: record, accountID: accountID, chatID: chatID,
            preparationID: preparationID, video: nil, attachmentID: TelegramPendingUploadItem.originalAttachmentID(itemID))
    }

    private func restorePayload(record: ArchiveFileRecord, accountID: Int64, chatID: Int64, preparationID: UUID,
                                video: TelegramUploadVideoMetadata?, attachmentID: String) async throws -> TelegramUploadFile {
        try Task.checkCancellation()
        guard record.identity == TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID),
              record.state == .stored, record.attachment.id == attachmentID,
              let mode = TelegramUploadMode(rawValue: record.attachment.kind),
              (mode == .video) == (video != nil),
              record.attachment.size == record.plaintextByteCount,
              record.attachment.name == telegramAttachmentName(record.attachment.name) else { throw TelegramUploadFileError.unavailable }
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + id.uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw TelegramUploadFileError.stagingFailed }
        let url = directory.appendingPathComponent("payload-" + id.uuidString)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        try await repository.export(record, to: url)
        try Task.checkCancellation()
        guard chmod(url.path, 0o600) == 0 else { throw TelegramUploadFileError.stagingFailed }
        let file = try await TelegramUploadFileIO.restoredStage(id: id, name: record.attachment.name,
            size: record.plaintextByteCount, mode: mode, url: url, directory: directory, video: video)
        try Task.checkCancellation()
        success = true
        return file
    }
}
