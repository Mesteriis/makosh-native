import Foundation
import MakoshCore
import TelegramCore

internal enum TelegramPendingUploadDisposition: Codable, Equatable, Sendable {
    case prepared, submissionStarted, accepted(localMessageID: String), acceptedBatch(messageIDs: [TelegramUploadQueueID]), cancelled
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
    let presentation: TelegramUploadPresentation
    let archive: TelegramPendingUploadArchive?
    let captionPolicy: TelegramUploadCaptionPolicy?
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
        presentation = file.attachment.kind == "file" ? .file : .media
        self.disposition = disposition
        archive = nil; captionPolicy = nil
    }
    init(id: UUID, revision: UUID = UUID(), accountID: Int64, chatID: Int64, title: String,
         captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
         originalDraft: TelegramComposerDraft?, replyTarget: TelegramComposerReplyTarget?,
         items: [TelegramPendingUploadItem], isGrouped: Bool, presentation: TelegramUploadPresentation? = nil,
         captionRules: TelegramUploadCaptionRules = .reference,
         mediaRules: TelegramUploadMediaRules = .legacy,
         archive: TelegramPendingUploadArchive? = nil,
         captionPolicy: TelegramUploadCaptionPolicy? = nil,
         disposition: TelegramPendingUploadDisposition = .prepared) throws {
        guard !items.isEmpty, captionPolicy != nil || captionRules != .current else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        guard presentation != .archive || archive != nil else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        guard mediaRules != .reference || (captionRules != .legacy && presentation != nil && items.allSatisfy({ $0.sourceFacts != nil })) else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        if let captionPolicy {
            guard captionRules == .current, mediaRules == .reference, presentation != nil,
                  items.allSatisfy({ $0.sourceFacts != nil && $0.metadata?.voice == nil && $0.metadata?.roundVideo == nil }),
                  captionPolicy.isValid(for: items.map(\.id)) else { throw TelegramPendingUploadPersistenceError.incompatibleData }
            schemaVersion = 19
        } else if archive != nil {
            guard captionRules == .reference, presentation != nil, items.allSatisfy({ $0.sourceFacts != nil }) else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            schemaVersion = mediaRules == .reference ? 18 : 16
        } else if items.contains(where: { $0.sourceFacts != nil }) {
            guard items.allSatisfy({ $0.sourceFacts != nil }), presentation != nil else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            schemaVersion = mediaRules == .reference ? 17 : captionRules == .reference ? 15 : 14
        } else if items.contains(where: { $0.metadata?.roundVideo != nil }) {
            schemaVersion = 13
        } else if let voice = items.first(where: { $0.metadata?.voice != nil })?.metadata?.voice {
            schemaVersion = voice.isOneTime ? 12 : 11
        } else {
            schemaVersion = items.contains(where: { $0.metadata?.gif != nil }) ? 10 : items.contains(where: { $0.metadata != nil }) ? 9 : presentation != nil ? 8 : items.contains(where: { $0.originalFile != nil }) ? 7 : 6
        }
        self.id = id; self.revision = revision; self.accountID = accountID; self.chatID = chatID
        self.title = title; self.captionInput = captionInput; self.captionAboveMedia = captionAboveMedia
        self.mediaSpoiler = mediaSpoiler; self.originalDraft = originalDraft; self.replyTarget = replyTarget
        self.items = items; self.isGrouped = isGrouped; self.disposition = disposition
        self.presentation = presentation ?? (items.allSatisfy { $0.file.attachment.kind == "file" } ? .file : .media)
        self.archive = archive; self.captionPolicy = captionPolicy
    }
    func updating(captionInput: TelegramComposerInput, captionAboveMedia: Bool, mediaSpoiler: Bool,
                  disposition: TelegramPendingUploadDisposition) -> Self {
        var result = self
        if schemaVersion < 6 { result.schemaVersion = videoCover != nil ? 5 : (video == nil ? 3 : 4) }
        result.revision = UUID(); result.captionInput = captionInput; result.captionAboveMedia = captionAboveMedia
        result.mediaSpoiler = mediaSpoiler; result.disposition = disposition
        return result
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, revision, accountID, chatID, title, captionInput, captionAboveMedia, mediaSpoiler
        case originalDraft, replyTarget, file, video, videoCover, disposition, items, isGrouped, presentation, archive, captionPolicy
    }
    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        if [14, 15, 16, 17, 18, 19].contains(schemaVersion) {
            let fields = try decoder.container(keyedBy: FieldKey.self)
            guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown source preparation field"))
            }
        }
        guard schemaVersion == 19 || !c.contains(.captionPolicy) else {
            throw DecodingError.dataCorruptedError(forKey: .captionPolicy, in: c, debugDescription: "Caption policy in an older preparation")
        }
        captionPolicy = schemaVersion == 19 ? try c.decode(TelegramUploadCaptionPolicy.self, forKey: .captionPolicy) : nil
        guard [16, 18, 19].contains(schemaVersion) || !c.contains(.archive) else {
            throw DecodingError.dataCorruptedError(forKey: .archive, in: c, debugDescription: "Archive in an older preparation")
        }
        archive = [16, 18].contains(schemaVersion) || (schemaVersion == 19 && c.contains(.archive))
            ? try c.decode(TelegramPendingUploadArchive.self, forKey: .archive) : nil
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
        guard schemaVersion >= 8 || !c.contains(.presentation) else {
            throw DecodingError.dataCorruptedError(forKey: .presentation, in: c, debugDescription: "Presentation in an older preparation")
        }
        if (6...19).contains(schemaVersion) {
            guard !c.contains(.file), !c.contains(.video), !c.contains(.videoCover) else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "Ambiguous preparation resources")
            }
            items = try c.decode([TelegramPendingUploadItem].self, forKey: .items)
            guard !items.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "Empty preparation")
            }
            isGrouped = try c.decode(Bool.self, forKey: .isGrouped)
            guard [14, 15, 16, 17, 18, 19].contains(schemaVersion) ? items.allSatisfy({ $0.sourceFacts != nil }) : items.allSatisfy({ $0.sourceFacts == nil }) else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "Incomplete or downgraded source facts")
            }
        } else {
            guard !c.contains(.items), !c.contains(.isGrouped) else {
                throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Batch data in legacy preparation")
            }
            items = [.init(id: id, file: try c.decode(ArchiveFileRecord.self, forKey: .file),
                video: try c.decodeIfPresent(TelegramUploadVideoMetadata.self, forKey: .video),
                videoCover: try c.decodeIfPresent(TelegramPendingUploadVideoCover.self, forKey: .videoCover))]
            isGrouped = false
        }
        presentation = schemaVersion >= 8 ? try c.decode(TelegramUploadPresentation.self, forKey: .presentation)
            : items.allSatisfy({ $0.file.attachment.kind == "file" }) ? .file : .media
        guard [16, 18, 19].contains(schemaVersion) || presentation != .archive else {
            throw DecodingError.dataCorruptedError(forKey: .presentation, in: c, debugDescription: "Archive presentation in an older preparation")
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
        if (6...19).contains(schemaVersion) {
            try c.encode(items, forKey: .items); try c.encode(isGrouped, forKey: .isGrouped)
            if schemaVersion >= 8 { try c.encode(presentation, forKey: .presentation) }
            if schemaVersion == 19 {
                guard let captionPolicy else { throw TelegramPendingUploadPersistenceError.incompatibleData }
                try c.encode(captionPolicy, forKey: .captionPolicy)
                try c.encodeIfPresent(archive, forKey: .archive)
            } else if [16, 18].contains(schemaVersion) {
                guard let archive else { throw TelegramPendingUploadPersistenceError.incompatibleData }
                try c.encode(archive, forKey: .archive)
            }
        } else {
            try c.encode(file, forKey: .file); try c.encodeIfPresent(video, forKey: .video); try c.encodeIfPresent(videoCover, forKey: .videoCover)
        }
    }
    static func archiveIdentity(accountID: Int64, chatID: Int64, preparationID: UUID) -> MessageArchiveIdentity {
        .init(service: "telegram", accountID: String(accountID), conversationID: String(chatID),
              messageID: "pending-upload:" + preparationID.uuidString.lowercased())
    }
    var captionRules: TelegramUploadCaptionRules { schemaVersion == 19 ? .current : schemaVersion >= 15 ? .reference : .legacy }
    var mediaRules: TelegramUploadMediaRules { schemaVersion >= 17 ? .reference : .legacy }
    var canCaptureArchive: Bool { [15, 17].contains(schemaVersion) || (schemaVersion == 19 && archive == nil) }
    var hasArchiveSchema: Bool { [16, 18].contains(schemaVersion) || (schemaVersion == 19 && archive != nil) }
    var isValid: Bool {
        guard (1...19).contains(schemaVersion), !(schemaVersion == 1 && captionAboveMedia),
              hasArchiveSchema == (archive != nil),
              schemaVersion == 19 ? captionPolicy?.isValid(for: items.map(\.id)) == true : captionPolicy == nil,
              presentation != .archive || (hasArchiveSchema && !isGrouped && !captionAboveMedia && !mediaSpoiler),
              [14, 15, 16, 17, 18, 19].contains(schemaVersion) ? items.allSatisfy({ $0.sourceFacts != nil && $0.metadata?.voice == nil && $0.metadata?.roundVideo == nil }) : items.allSatisfy({ $0.sourceFacts == nil }),
              schemaVersion == 13 || items.allSatisfy({ $0.metadata?.roundVideo == nil }),
              schemaVersion >= 6 || (items.count == 1 && (schemaVersion >= 4) == (video != nil) && (schemaVersion == 5) == (videoCover != nil)),
              (schemaVersion >= 7
                ? (schemaVersion >= 8 || items.contains(where: { $0.originalFile != nil })) && items.allSatisfy({ $0.file.attachment.kind != "photo" || $0.originalFile != nil })
                : items.allSatisfy({ $0.originalFile == nil })),
              ([14, 15, 16, 17, 18, 19].contains(schemaVersion) ? true : schemaVersion == 13 ? items.count == 1 && items[0].metadata?.roundVideo != nil && !isGrouped && presentation == .media && captionInput.formattedText.text.isEmpty && !captionAboveMedia && !mediaSpoiler
                : [11, 12].contains(schemaVersion) ? items.count == 1 && items[0].metadata?.voice?.isOneTime == (schemaVersion == 12) && !isGrouped && presentation == .file && captionInput.formattedText.text.isEmpty && !captionAboveMedia && !mediaSpoiler
                : items.allSatisfy({ $0.metadata?.voice == nil }) && (schemaVersion == 10 ? items.contains(where: { $0.metadata?.gif != nil })
                : schemaVersion == 9 ? items.contains(where: { $0.metadata != nil }) && items.allSatisfy({ $0.metadata?.gif == nil })
                : items.allSatisfy({ $0.metadata == nil }))),
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ $0.isValid(identity: Self.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: id), legacy: schemaVersion < 6) }),
              !(schemaVersion < 3 && mediaSpoiler),
              schemaVersion >= 8 || (!mediaSpoiler && !captionAboveMedia) || items.allSatisfy({ ["photo", "video"].contains($0.file.attachment.kind) }),
              schemaVersion < 8 || presentation != .media || TelegramPendingUploadItem.allowsMedia(items, rules: mediaRules),
              schemaVersion < 8 || !isGrouped || presentation.allowsGrouping(items),
              id != Self.zeroUUID, revision != Self.zeroUUID,
              title.utf8.count <= 4096, !title.utf8.contains(0),
              captionInput.formattedText.text.utf8.count <= 64 * 1024,
              (try? TelegramComposerInput(formattedText: captionInput.formattedText, selection: captionInput.selection)) == captionInput,
              replyTarget?.isValid ?? true else { return false }
        let resources = items.flatMap { [$0.file] + ($0.videoCover.map { [$0.file] } ?? []) + ($0.originalFile.map { [$0] } ?? []) } + (archive.map { [$0.file] } ?? [])
        guard Set(resources.map(\.id)).count == resources.count,
              archive?.isValid(identity: Self.archiveIdentity(accountID: accountID, chatID: chatID, preparationID: id), items: items) ?? true else { return false }
        if let originalDraft {
            guard originalDraft.isValid, originalDraft.accountID == accountID, originalDraft.chatID == chatID,
                  originalDraft.revision != Self.zeroUUID, originalDraft.replyTarget == replyTarget,
                  originalDraft.forwardIntent == nil else { return false }
        }
        if case let .accepted(localMessageID) = disposition {
            guard schemaVersion < 6, !localMessageID.isEmpty, localMessageID.utf8.count <= 1024,
                  !localMessageID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        }
        if case let .acceptedBatch(messageIDs) = disposition {
            guard let projected = try? captionRules.projection(captionInput.formattedText) else { return false }
            let leadingText = captionRules.hasLeadingText(itemCount: items.count, isGrouped: isGrouped,
                singleItemCanHaveCaption: items.first.flatMap { captionPolicy?.canHaveCaption(itemID: $0.id, mode: presentation == .file ? .file : TelegramUploadMode(rawValue: $0.file.attachment.kind) ?? .file) } ?? TelegramUploadCaptionRules.canHaveCaption(kind: presentation == .file ? "file" : items.first?.file.attachment.kind,
                    metadata: items.first?.metadata, selectionMIME: items.first?.sourceFacts?.selectionMIME), projectedCaption: projected)
            let expectedCount = presentation == .archive ? 1 : items.count + (leadingText ? 1 : 0)
            guard schemaVersion >= 6, messageIDs.count == expectedCount,
                  Set(messageIDs).count == messageIDs.count,
                  messageIDs.allSatisfy({ $0.peerID == chatID && $0.namespace == Namespaces.Message.Local }) else { return false }
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
