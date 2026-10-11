import Foundation
import Darwin
import MakoshCore

/// Pending composer media is distinct from received-message archive resources.
actor TelegramPendingUploadFiles {
    private let repository: ArchiveFileRepository
    init(repository: ArchiveFileRepository) { self.repository = repository }

    func save(file: TelegramUploadFile, accountID: Int64, chatID: Int64, preparationID: UUID) async throws -> ArchiveFileRecord {
        try Task.checkCancellation()
        try TelegramUploadFileIO.validateOwnedStage(file)
        // Open/freeze the source FD before the first suspension; cache unlink is safe.
        let capture = try ArchiveFileCapture(file: file.url, byteCount: file.size)
        guard file.name == telegramAttachmentName(file.name) else { throw TelegramUploadFileError.unavailable }
        guard file.mode == .video || file.video == nil else { throw TelegramUploadFileError.unavailable }
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
            attachment: MessageArchiveAttachment(id: "prepared", kind: file.mode.rawValue, name: file.name, size: file.size))
    }

    func restore(record: ArchiveFileRecord, accountID: Int64, chatID: Int64, preparationID: UUID, video: TelegramUploadVideoMetadata? = nil) async throws -> TelegramUploadFile {
        try Task.checkCancellation()
        guard record.identity == TelegramPendingUploadDraft.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: preparationID),
              record.state == .stored, record.attachment.id == "prepared",
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
