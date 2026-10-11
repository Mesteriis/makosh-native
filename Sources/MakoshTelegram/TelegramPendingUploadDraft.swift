import Foundation
import MakoshCore

internal enum TelegramPendingUploadDisposition: Codable, Equatable, Sendable {
    case prepared, submissionStarted, accepted(localMessageID: String), cancelled
}

/// Owned draft resource identity, never an engine MessageId or a history event.
internal struct TelegramPendingUploadDraft: Codable, Equatable, Sendable {
    private(set) var schemaVersion: Int
    let id: UUID
    private(set) var revision: UUID
    let accountID: Int64
    let chatID: Int64
    let title: String
    private(set) var captionInput: TelegramComposerInput
    private(set) var captionAboveMedia: Bool
    private(set) var mediaSpoiler: Bool
    let originalDraft: TelegramComposerDraft?
    let replyTarget: TelegramComposerReplyTarget?
    let items: [TelegramPendingUploadItem]
    let isGrouped: Bool
    private(set) var disposition: TelegramPendingUploadDisposition
    // Legacy single-file consumers must explicitly reject schema6 before use.
    var file: ArchiveFileRecord { items[0].file }
    var video: TelegramUploadVideoMetadata? { items[0].video }
    var videoCover: TelegramPendingUploadVideoCover? { items[0].videoCover }
    init(id: UUID, revision: UUID = UUID(), accountID: Int64, chatID: Int64, title: String,
         captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false, originalDraft: TelegramComposerDraft?,
         replyTarget: TelegramComposerReplyTarget?, file: ArchiveFileRecord, video: TelegramUploadVideoMetadata? = nil,
         videoCover: TelegramPendingUploadVideoCover? = nil,
         disposition: TelegramPendingUploadDisposition = .prepared) {
        schemaVersion = videoCover != nil ? 5 : (video == nil ? 3 : 4); self.id = id; self.revision = revision; self.accountID = accountID
        self.chatID = chatID; self.title = title; self.captionInput = captionInput
        self.captionAboveMedia = captionAboveMedia
        self.mediaSpoiler = mediaSpoiler
        self.originalDraft = originalDraft; self.replyTarget = replyTarget
        items = [.init(id: id, file: file, video: video, videoCover: videoCover)]; isGrouped = false
        self.disposition = disposition
    }
    init(id: UUID, revision: UUID = UUID(), accountID: Int64, chatID: Int64, title: String,
         captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
         originalDraft: TelegramComposerDraft?, replyTarget: TelegramComposerReplyTarget?,
         items: [TelegramPendingUploadItem], isGrouped: Bool,
         disposition: TelegramPendingUploadDisposition = .prepared) throws {
        guard !items.isEmpty else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        schemaVersion = 6; self.id = id; self.revision = revision; self.accountID = accountID; self.chatID = chatID
        self.title = title; self.captionInput = captionInput; self.captionAboveMedia = captionAboveMedia
        self.mediaSpoiler = mediaSpoiler; self.originalDraft = originalDraft; self.replyTarget = replyTarget
        self.items = items; self.isGrouped = isGrouped; self.disposition = disposition
    }
    func updating(captionInput: TelegramComposerInput, captionAboveMedia: Bool, mediaSpoiler: Bool,
                  disposition: TelegramPendingUploadDisposition) -> Self {
        var result = self
        if schemaVersion < 6 { result.schemaVersion = videoCover != nil ? 5 : (video == nil ? 3 : 4) }
        result.revision = UUID(); result.captionInput = captionInput; result.captionAboveMedia = captionAboveMedia
        result.mediaSpoiler = mediaSpoiler; result.disposition = disposition
        return result
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, revision, accountID, chatID, title, captionInput, captionAboveMedia, mediaSpoiler
        case originalDraft, replyTarget, file, video, videoCover, disposition, items, isGrouped
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id); revision = try c.decode(UUID.self, forKey: .revision)
        accountID = try c.decode(Int64.self, forKey: .accountID); chatID = try c.decode(Int64.self, forKey: .chatID)
        title = try c.decode(String.self, forKey: .title)
        captionInput = try c.decode(TelegramComposerInput.self, forKey: .captionInput)
        // Only the original schema may omit placement. New data must be explicit.
        captionAboveMedia = schemaVersion == 1
            ? try c.decodeIfPresent(Bool.self, forKey: .captionAboveMedia) ?? false
            : try c.decode(Bool.self, forKey: .captionAboveMedia)
        mediaSpoiler = schemaVersion < 3
            ? try c.decodeIfPresent(Bool.self, forKey: .mediaSpoiler) ?? false
            : try c.decode(Bool.self, forKey: .mediaSpoiler)
        originalDraft = try c.decodeIfPresent(TelegramComposerDraft.self, forKey: .originalDraft)
        replyTarget = try c.decodeIfPresent(TelegramComposerReplyTarget.self, forKey: .replyTarget)
        if schemaVersion == 6 {
            guard !c.contains(.file), !c.contains(.video), !c.contains(.videoCover) else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "Ambiguous preparation resources")
            }
            items = try c.decode([TelegramPendingUploadItem].self, forKey: .items)
            guard !items.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "Empty preparation")
            }
            isGrouped = try c.decode(Bool.self, forKey: .isGrouped)
        } else {
            guard !c.contains(.items), !c.contains(.isGrouped) else {
                throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Batch data in legacy preparation")
            }
            items = [.init(id: id, file: try c.decode(ArchiveFileRecord.self, forKey: .file),
                video: try c.decodeIfPresent(TelegramUploadVideoMetadata.self, forKey: .video),
                videoCover: try c.decodeIfPresent(TelegramPendingUploadVideoCover.self, forKey: .videoCover))]
            isGrouped = false
        }
        disposition = try c.decode(TelegramPendingUploadDisposition.self, forKey: .disposition)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(id, forKey: .id); try c.encode(revision, forKey: .revision)
        try c.encode(accountID, forKey: .accountID); try c.encode(chatID, forKey: .chatID); try c.encode(title, forKey: .title)
        try c.encode(captionInput, forKey: .captionInput); try c.encode(captionAboveMedia, forKey: .captionAboveMedia)
        try c.encode(mediaSpoiler, forKey: .mediaSpoiler); try c.encodeIfPresent(originalDraft, forKey: .originalDraft)
        try c.encodeIfPresent(replyTarget, forKey: .replyTarget); try c.encode(disposition, forKey: .disposition)
        if schemaVersion == 6 {
            try c.encode(items, forKey: .items); try c.encode(isGrouped, forKey: .isGrouped)
        } else {
            try c.encode(file, forKey: .file); try c.encodeIfPresent(video, forKey: .video); try c.encodeIfPresent(videoCover, forKey: .videoCover)
        }
    }
    static func archiveIdentity(accountID: Int64, chatID: Int64, preparationID: UUID) -> MessageArchiveIdentity {
        .init(service: "telegram", accountID: String(accountID), conversationID: String(chatID),
              messageID: "pending-upload:" + preparationID.uuidString.lowercased())
    }
    var isValid: Bool {
        guard [1, 2, 3, 4, 5, 6].contains(schemaVersion), !(schemaVersion == 1 && captionAboveMedia),
              schemaVersion == 6 || (items.count == 1 && (schemaVersion >= 4) == (video != nil) && (schemaVersion == 5) == (videoCover != nil)),
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.isValid(identity: Self.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: id), legacy: schemaVersion < 6) }),
              !(schemaVersion < 3 && mediaSpoiler),
              (!mediaSpoiler && !captionAboveMedia) || items.allSatisfy({ ["photo", "video"].contains($0.file.attachment.kind) }),
              id != Self.zeroUUID, revision != Self.zeroUUID,
              title.utf8.count <= 4096, !title.utf8.contains(0),
              captionInput.formattedText.text.utf8.count <= 64 * 1024,
              (try? TelegramComposerInput(formattedText: captionInput.formattedText, selection: captionInput.selection)) == captionInput,
              replyTarget?.isValid ?? true else { return false }
        let resources = items.flatMap { [$0.file] + ($0.videoCover.map { [$0.file] } ?? []) }
        guard Set(resources.map(\.id)).count == resources.count else { return false }
        if let originalDraft {
            guard originalDraft.isValid, originalDraft.accountID == accountID, originalDraft.chatID == chatID,
                  originalDraft.revision != Self.zeroUUID, originalDraft.replyTarget == replyTarget,
                  originalDraft.forwardIntent == nil else { return false }
        }
        if case let .accepted(localMessageID) = disposition {
            guard schemaVersion < 6, !localMessageID.isEmpty, localMessageID.utf8.count <= 1024,
                  !localMessageID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        }
        guard let encoded = try? JSONEncoder().encode(self), encoded.count <= 512 * 1024 - 64 else { return false }
        return true
    }
    static let zeroUUID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func isObjectKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,47,95].contains($0) } &&
        value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
