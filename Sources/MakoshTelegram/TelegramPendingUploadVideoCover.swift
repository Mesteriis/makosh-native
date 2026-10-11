import Foundation
import MakoshCore

struct TelegramPendingUploadVideoCover: Codable, Equatable, Sendable {
    let file: ArchiveFileRecord
    let width: Int32
    let height: Int32

    func isValid(identity: MessageArchiveIdentity) -> Bool {
        width > 0 && height > 0 && width <= 320 && height <= 320 && file.identity == identity &&
            file.state == .stored && file.id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) &&
            file.attachment.id == "video-cover" && file.attachment.kind == "photo" &&
            !file.attachment.name.isEmpty && file.attachment.name.utf8.count <= 1024 &&
            file.attachment.name == telegramAttachmentName(file.attachment.name) &&
            file.plaintextByteCount > 0 && file.plaintextByteCount <= 1_048_576 &&
            file.attachment.size == file.plaintextByteCount && file.byteCount > 0 && file.byteCount <= 2_097_152 &&
            TelegramPendingUploadDraft.isHash(file.sha256) && TelegramPendingUploadDraft.isHash(file.plaintextSHA256) &&
            TelegramPendingUploadDraft.isHash(file.storageID) && TelegramPendingUploadDraft.isObjectKey(file.objectKey) &&
            file.capturedAt.timeIntervalSince1970.isFinite
    }
}

func telegramPendingUploadCoverMatches(_ stored: TelegramPendingUploadVideoCover?, _ cover: TelegramUploadVideoCover?) -> Bool {
    switch (stored, cover) {
    case (nil, nil): return true
    case let (.some(stored), .some(cover)):
        return stored.width == cover.width && stored.height == cover.height &&
            stored.file.plaintextByteCount == cover.size && stored.file.plaintextSHA256 == cover.sha256 &&
            stored.file.attachment.name.utf8.elementsEqual(cover.name.utf8)
    default: return false
    }
}
