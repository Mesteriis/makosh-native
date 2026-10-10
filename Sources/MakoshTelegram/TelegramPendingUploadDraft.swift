import Foundation
import MakoshCore

internal enum TelegramPendingUploadDisposition: Codable, Equatable, Sendable {
    case prepared, submissionStarted, accepted(localMessageID: String), cancelled
}

/// Owned draft resource identity, never an engine MessageId or a history event.
internal struct TelegramPendingUploadDraft: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let revision: UUID
    let accountID: Int64
    let chatID: Int64
    let title: String
    let captionInput: TelegramComposerInput
    let originalDraft: TelegramComposerDraft?
    let replyTarget: TelegramComposerReplyTarget?
    let file: ArchiveFileRecord
    let disposition: TelegramPendingUploadDisposition
    init(id: UUID, revision: UUID = UUID(), accountID: Int64, chatID: Int64, title: String,
         captionInput: TelegramComposerInput, originalDraft: TelegramComposerDraft?,
         replyTarget: TelegramComposerReplyTarget?, file: ArchiveFileRecord,
         disposition: TelegramPendingUploadDisposition = .prepared) {
        schemaVersion = 1; self.id = id; self.revision = revision; self.accountID = accountID
        self.chatID = chatID; self.title = title; self.captionInput = captionInput
        self.originalDraft = originalDraft; self.replyTarget = replyTarget; self.file = file
        self.disposition = disposition
    }
    static func archiveIdentity(accountID: Int64, chatID: Int64, preparationID: UUID) -> MessageArchiveIdentity {
        .init(service: "telegram", accountID: String(accountID), conversationID: String(chatID),
              messageID: "pending-upload:" + preparationID.uuidString.lowercased())
    }
    var isValid: Bool {
        guard schemaVersion == 1, id != Self.zeroUUID, revision != Self.zeroUUID,
              title.utf8.count <= 4096, !title.utf8.contains(0),
              captionInput.formattedText.text.utf8.count <= 64 * 1024,
              (try? TelegramComposerInput(formattedText: captionInput.formattedText, selection: captionInput.selection)) == captionInput,
              replyTarget?.isValid ?? true,
              file.state == .stored, file.id != Self.zeroUUID,
              file.identity == Self.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: id),
              file.attachment.id == "prepared", ["file", "photo"].contains(file.attachment.kind),
              !file.attachment.name.isEmpty, file.attachment.name.utf8.count <= 1024,
              !file.attachment.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !file.attachment.name.contains("/"), !file.attachment.name.contains("\\"),
              file.attachment.name != ".", file.attachment.name != "..",
              file.plaintextByteCount >= 0, file.plaintextByteCount <= 4 * 1024 * 1024 * 1024,
              file.attachment.size == file.plaintextByteCount,
              file.byteCount > 0, file.byteCount <= 4 * 1024 * 1024 * 1024 + 1024 * 1024,
              Self.isHash(file.sha256), Self.isHash(file.plaintextSHA256), Self.isHash(file.storageID),
              file.capturedAt.timeIntervalSince1970.isFinite, Self.isObjectKey(file.objectKey) else { return false }
        if let originalDraft {
            guard originalDraft.isValid, originalDraft.accountID == accountID, originalDraft.chatID == chatID,
                  originalDraft.revision != Self.zeroUUID, originalDraft.replyTarget == replyTarget,
                  originalDraft.forwardIntent == nil else { return false }
        }
        if case let .accepted(localMessageID) = disposition {
            guard !localMessageID.isEmpty, localMessageID.utf8.count <= 1024,
                  !localMessageID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        }
        guard let encoded = try? JSONEncoder().encode(self), encoded.count <= 512 * 1024 - 64 else { return false }
        return true
    }
    private static let zeroUUID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func isObjectKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,47,95].contains($0) } &&
        value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
