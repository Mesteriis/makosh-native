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
        let identity = TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID)
        let record = try await repository.capture(frozen,
            identity: identity,
            attachment: MessageArchiveAttachment(id: itemID.map(TelegramPendingUploadItem.coverAttachmentID) ?? "video-cover", kind: "photo", name: cover.name, size: cover.size),
            defaultEnabled: TelegramConversationFilePolicyController.defaultEnabled(identity: identity))
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

    static func captureArchive(_ file: TelegramUploadFile) throws -> ArchiveFileCapture {
        try Task.checkCancellation()
        try validateArchiveStage(file)
        return try ArchiveFileCapture(file: file.url, byteCount: file.size)
    }

    private static func validateArchiveStage(_ file: TelegramUploadFile) throws {
        guard file.id != TelegramPendingUploadDraft.zeroUUID, file.name == "Telegram Archive.zip",
              file.mode == .file, file.metadata == nil, file.video == nil, file.videoCover == nil,
              file.pixelWidth == nil, file.pixelHeight == nil,
              file.size >= 22, file.size < Int64(UInt32.max) else { throw TelegramUploadFileError.unavailable }
        try TelegramUploadFileIO.validateOwnedStage(file)
    }

    func saveArchive(_ archive: TelegramUploadArchiveIO.Archive, sources: [TelegramUploadArchiveIO.Source],
                     archiveID: UUID, accountID: Int64, chatID: Int64, preparationID: UUID,
                     capture: ArchiveFileCapture? = nil) async throws -> ArchiveFileRecord {
        try Task.checkCancellation()
        guard archiveID != TelegramPendingUploadDraft.zeroUUID, preparationID != TelegramPendingUploadDraft.zeroUUID,
              !sources.contains(where: { $0.itemID == archiveID || $0.file.id == archiveID }) else {
            throw TelegramUploadFileError.unavailable
        }
        // A supplied held capture never bypasses the plain owned ZIP profile.
        try Self.validateArchiveStage(archive.file)
        let frozen = try capture ?? Self.captureArchive(archive.file)
        let digest = try frozen.plaintextSHA256()
        try Task.checkCancellation()
        // Validate and hash the same held ZIP inode before the first storage write.
        try await TelegramUploadArchiveValidation.validate(archive, sources: sources, expectedPlaintextSHA256: digest)
        try Task.checkCancellation()
        let identity = TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID)
        let record = try await repository.capture(frozen, identity: identity,
            attachment: .init(id: TelegramPendingUploadArchive.attachmentID(archiveID), kind: "file",
                              name: archive.file.name, size: archive.file.size),
            defaultEnabled: TelegramConversationFilePolicyController.defaultEnabled(identity: identity))
        guard record.plaintextByteCount == archive.file.size, record.plaintextSHA256 == digest else {
            throw TelegramUploadFileError.unavailable
        }
        return record
    }

    func restoreArchive(record: ArchiveFileRecord, archiveID: UUID, accountID: Int64, chatID: Int64,
                        preparationID: UUID) async throws -> TelegramUploadFile {
        try Task.checkCancellation()
        let identity = TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID)
        let attachmentID = TelegramPendingUploadArchive.attachmentID(archiveID)
        guard archiveID != TelegramPendingUploadDraft.zeroUUID, preparationID != TelegramPendingUploadDraft.zeroUUID,
              case .some(.outgoing) = record.purpose,
              record.attachment.kind == "file", record.attachment.name == "Telegram Archive.zip",
              record.plaintextByteCount >= 22, record.plaintextByteCount < Int64(UInt32.max),
              TelegramPendingUploadItem.validRecord(record, identity: identity, attachmentID: attachmentID) else {
            throw TelegramUploadFileError.unavailable
        }
        // Export authenticates the entire immutable record; the bundle owner
        // inspects this restored ZIP against its separately restored sources.
        return try await restorePayload(record: record, accountID: accountID, chatID: chatID,
            preparationID: preparationID, video: nil, attachmentID: attachmentID)
    }

    static func captureFile(_ file: TelegramUploadFile) throws -> ArchiveFileCapture {
        try TelegramUploadFileIO.validateOwnedStage(file)
        try TelegramUploadFileIO.validateMetadata(file)
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
        if file.mode != .file || file.metadata != nil {
            let verified = try await TelegramUploadFileIO.restoredStage(id: file.id, name: file.name, size: file.size,
                mode: file.mode, url: file.url, directory: file.directory, video: file.video, metadata: file.metadata)
            guard verified.pixelWidth == file.pixelWidth, verified.pixelHeight == file.pixelHeight,
                  verified.video == file.video, verified.metadata == file.metadata else {
                throw file.mode == .video ? TelegramUploadFileError.invalidVideo : .invalidImage
            }
        }
        try Task.checkCancellation()
        let identity = TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID)
        return try await repository.capture(capture,
            identity: identity,
            attachment: MessageArchiveAttachment(id: itemID.map(TelegramPendingUploadItem.attachmentID) ?? "prepared", kind: file.mode.rawValue, name: file.name, size: file.size),
            defaultEnabled: TelegramConversationFilePolicyController.defaultEnabled(identity: identity))
    }

    func restore(record: ArchiveFileRecord, accountID: Int64, chatID: Int64, preparationID: UUID, video: TelegramUploadVideoMetadata? = nil,
                 itemID: UUID? = nil, metadata: TelegramUploadMetadata? = nil) async throws -> TelegramUploadFile {
        try await restorePayload(record: record, accountID: accountID, chatID: chatID,
            preparationID: preparationID, video: video, attachmentID: itemID.map(TelegramPendingUploadItem.attachmentID) ?? "prepared", metadata: metadata)
    }

    func saveOriginal(_ file: TelegramUploadFile, accountID: Int64, chatID: Int64, preparationID: UUID,
                      itemID: UUID, capture: ArchiveFileCapture) async throws -> ArchiveFileRecord {
        guard file.mode == .file, file.metadata == nil, file.size <= 20 * 1024 * 1024 else { throw TelegramUploadFileError.unavailable }
        try Task.checkCancellation()
        let identity = TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID)
        return try await repository.capture(capture,
            identity: identity,
            attachment: .init(id: TelegramPendingUploadItem.originalAttachmentID(itemID), kind: "file", name: file.name, size: file.size),
            defaultEnabled: TelegramConversationFilePolicyController.defaultEnabled(identity: identity))
    }

    func restoreOriginal(_ record: ArchiveFileRecord, accountID: Int64, chatID: Int64, preparationID: UUID, itemID: UUID) async throws -> TelegramUploadFile {
        guard record.attachment.kind == "file", record.plaintextByteCount <= 20 * 1024 * 1024 else { throw TelegramUploadFileError.unavailable }
        return try await restorePayload(record: record, accountID: accountID, chatID: chatID,
            preparationID: preparationID, video: nil, attachmentID: TelegramPendingUploadItem.originalAttachmentID(itemID))
    }

    private func restorePayload(record: ArchiveFileRecord, accountID: Int64, chatID: Int64, preparationID: UUID,
                                video: TelegramUploadVideoMetadata?, attachmentID: String, metadata: TelegramUploadMetadata? = nil) async throws -> TelegramUploadFile {
        try Task.checkCancellation()
        guard record.identity == TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID),
              TelegramPendingUploadItem.isDurable(record), record.attachment.id == attachmentID,
              let mode = TelegramUploadMode(rawValue: record.attachment.kind),
              (mode == .video) == (video != nil),
              metadata.map({ (mode == .file || (mode == .video && ($0.gif != nil || $0.roundVideo != nil))) && $0.isValid }) ?? true,
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
            size: record.plaintextByteCount, mode: mode, url: url, directory: directory, video: video, metadata: metadata)
        try Task.checkCancellation()
        success = true
        return file
    }
}
