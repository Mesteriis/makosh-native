import Foundation
import MakoshCore
import UniformTypeIdentifiers

/// Old pointers require a visual payload; new picker preparations follow source options even for documents.
enum TelegramUploadMediaRules: Equatable, Sendable {
    case legacy, reference

    func allowsMedia(hasVisual: Bool, facts: [TelegramUploadSourceFacts?]) -> Bool {
        let complete = facts.compactMap { $0 }
        if self == .legacy || complete.isEmpty {
            guard hasVisual else { return false }
        }
        return complete.isEmpty || (complete.count == facts.count && TelegramUploadSourceClassifier.options(for: complete).contains(.media))
    }
}

/// Presentation changes select an existing resource; they never rename JPEG bytes into an original.
public enum TelegramUploadPresentation: String, Codable, Equatable, Sendable {
    case media, file, archive

    func allowsGrouping(_ items: [TelegramUploadBatchItem]) -> Bool {
        allowsGrouping(facts: items.map(\.sourceFacts), files: items.map {
            (name: $0.originalFile?.name ?? $0.file.name, isVisual: $0.file.mode != .file, metadata: $0.file.metadata)
        })
    }
    func allowsGrouping(_ items: [TelegramPendingUploadItem]) -> Bool {
        allowsGrouping(facts: items.map(\.sourceFacts), files: items.map {
            (name: $0.originalFile?.attachment.name ?? $0.file.attachment.name,
             isVisual: $0.file.attachment.kind != "file", metadata: $0.metadata)
        })
    }
    private func allowsGrouping(facts: [TelegramUploadSourceFacts?], files: [(name: String, isVisual: Bool, metadata: TelegramUploadMetadata?)]) -> Bool {
        guard self != .archive else { return false }
        guard facts.contains(where: { $0 != nil }) else { return allowsGrouping(files) }
        let complete = facts.compactMap { $0 }
        guard complete.count == files.count, TelegramUploadSourceClassifier.allowsGrouping(for: complete, presentation: self),
              files.allSatisfy({ $0.metadata?.isValid ?? true }),
              !files.contains(where: { $0.metadata?.voice != nil || $0.metadata?.roundVideo != nil }),
              !files.contains(where: { if case .webP = $0.metadata { true } else { false } }) else { return false }
        return zip(complete, files).allSatisfy { facts, file in
            facts.grouping == (file.metadata?.audio != nil ? .music : .ordinary)
        }
    }

    func allowsGrouping(_ files: [(name: String, isVisual: Bool)]) -> Bool {
        guard self != .archive, !files.isEmpty, !files.contains(where: { ($0.name as NSString).pathExtension.lowercased() == "webp" }),
              self != .media || files.allSatisfy(\.isVisual) else { return false }
        let audio = files.map { UTType(filenameExtension: ($0.name as NSString).pathExtension)?.conforms(to: .audio) == true }
        return !audio.contains(true) || audio.allSatisfy { $0 }
    }

    func allowsGrouping(_ files: [(name: String, isVisual: Bool, metadata: TelegramUploadMetadata?)]) -> Bool {
        guard self != .archive else { return false }
        if files.contains(where: { $0.metadata?.voice != nil || $0.metadata?.roundVideo != nil }) { return false }
        if files.contains(where: { if case .webP = $0.metadata { true } else { false } }) { return false }
        if files.contains(where: { if case .audio = $0.metadata { true } else { false } }) {
            return self == .file && files.allSatisfy {
                guard case let .audio(audio) = $0.metadata else { return false }
                return !$0.isVisual && audio.isValid && ($0.name as NSString).pathExtension.lowercased() != "webp"
            }
        }
        return allowsGrouping(files.map { (name: $0.metadata?.gif != nil ? "original.gif" : $0.name, isVisual: $0.isVisual) })
    }
}

/// Stable preparation identity, independent of preview position or restored tmp path.
internal struct TelegramPendingUploadItem: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let file: ArchiveFileRecord
    let video: TelegramUploadVideoMetadata?
    let videoCover: TelegramPendingUploadVideoCover?
    let originalFile: ArchiveFileRecord?
    let metadata: TelegramUploadMetadata?
    let sourceFacts: TelegramUploadSourceFacts?

    init(id: UUID, file: ArchiveFileRecord, video: TelegramUploadVideoMetadata? = nil,
         videoCover: TelegramPendingUploadVideoCover? = nil, originalFile: ArchiveFileRecord? = nil,
         metadata: TelegramUploadMetadata? = nil, sourceFacts: TelegramUploadSourceFacts? = nil) {
        self.id = id; self.file = file; self.video = video; self.videoCover = videoCover; self.originalFile = originalFile
        self.metadata = metadata
        self.sourceFacts = sourceFacts
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, file, video, videoCover, originalFile, metadata, sourceFacts }
    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: FieldKey.self)
        guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown preparation resource field"))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); file = try c.decode(ArchiveFileRecord.self, forKey: .file)
        video = try c.decodeIfPresent(TelegramUploadVideoMetadata.self, forKey: .video)
        videoCover = try c.decodeIfPresent(TelegramPendingUploadVideoCover.self, forKey: .videoCover)
        originalFile = try c.decodeIfPresent(ArchiveFileRecord.self, forKey: .originalFile)
        // A null discriminator cannot silently turn typed media into a generic file.
        metadata = c.contains(.metadata) ? try c.decode(TelegramUploadMetadata.self, forKey: .metadata) : nil
        sourceFacts = c.contains(.sourceFacts) ? try c.decode(TelegramUploadSourceFacts.self, forKey: .sourceFacts) : nil
        guard metadata == nil || (metadata?.roundVideo != nil
            ? video != nil && !c.contains(.videoCover) && !c.contains(.originalFile)
            : metadata?.gif != nil
            ? video != nil && originalFile != nil && !c.contains(.videoCover)
            : !c.contains(.video) && !c.contains(.videoCover) && !c.contains(.originalFile)) else {
            throw DecodingError.dataCorruptedError(forKey: .metadata, in: c, debugDescription: "Conflicting typed preparation resources")
        }
    }

    static func attachmentID(_ id: UUID) -> String { "prepared:" + id.uuidString.lowercased() }
    static func coverAttachmentID(_ id: UUID) -> String { "video-cover:" + id.uuidString.lowercased() }
    static func originalAttachmentID(_ id: UUID) -> String { "original:" + id.uuidString.lowercased() }

    func isValid(identity: MessageArchiveIdentity, legacy: Bool) -> Bool {
        guard id != TelegramPendingUploadDraft.zeroUUID &&
            (sourceFacts == nil || validSourceFacts) &&
            (metadata.map { value in
                value.roundVideo != nil ? validRoundVideo : value.gif != nil ? validGIFPair : file.attachment.kind == "file" && video == nil && videoCover == nil && originalFile == nil && value.isValid
            } ?? true) &&
            (file.attachment.kind == "video") == (video != nil) &&
            (video?.isValid(name: file.attachment.name, size: file.plaintextByteCount) ?? true) &&
            (videoCover == nil || video != nil) &&
            (videoCover?.isValid(identity: identity, attachmentID: legacy ? "video-cover" : Self.coverAttachmentID(id)) ?? true) &&
            Self.validRecord(file, identity: identity, attachmentID: legacy ? "prepared" : Self.attachmentID(id)) else { return false }
        if let voice = metadata?.voice {
            guard file.plaintextByteCount > 0, file.plaintextByteCount <= 20 * 1024 * 1024,
                  voice.plaintextSHA256 == file.plaintextSHA256 else { return false }
        }
        guard let originalFile else { return true }
        return !legacy && (file.attachment.kind == "photo" || metadata?.gif != nil) && originalFile.attachment.kind == "file" &&
            originalFile.plaintextByteCount <= 20 * 1024 * 1024 &&
            Self.validRecord(originalFile, identity: identity, attachmentID: Self.originalAttachmentID(id))
    }

    private var validSourceFacts: Bool {
        guard let facts = sourceFacts, facts.isValid, facts.itemID == id,
              metadata?.voice == nil, metadata?.roundVideo == nil,
              facts.role == (originalFile == nil ? .prepared : .original),
              facts.grouping == (metadata?.audio != nil ? .music : .ordinary) else { return false }
        let raw = originalFile ?? file
        return facts.name.utf8.elementsEqual(raw.attachment.name.utf8) && facts.byteCount == raw.plaintextByteCount &&
            facts.plaintextSHA256 == raw.plaintextSHA256
    }

    static func allowsMedia(_ items: [Self], rules: TelegramUploadMediaRules = .legacy) -> Bool {
        rules.allowsMedia(hasVisual: items.contains(where: { ["photo", "video"].contains($0.file.attachment.kind) }),
            facts: items.map(\.sourceFacts))
    }

    private var validRoundVideo: Bool {
        guard let round = metadata?.roundVideo else { return false }
        return file.attachment.kind == "video" && videoCover == nil && originalFile == nil &&
            round.isValid(video: video, name: file.attachment.name, size: file.plaintextByteCount) &&
            round.plaintextSHA256 == file.plaintextSHA256
    }

    private var validGIFPair: Bool {
        guard let gif = metadata?.gif, gif.isValid, let video, let originalFile else { return false }
        return file.attachment.kind == "video" && videoCover == nil && !video.hasAudio &&
            file.plaintextByteCount <= 128 * 1024 * 1024 && originalFile.plaintextByteCount > 0 &&
            video.width == gif.width && video.height == gif.height &&
            gif.sourceSHA256 == originalFile.plaintextSHA256 &&
            file.attachment.name == telegramAttachmentName((originalFile.attachment.name as NSString).deletingPathExtension + ".mp4")
    }

    func matchesOriginal(_ staged: TelegramUploadFile?) -> Bool {
        switch (originalFile, staged) {
        case (nil, nil): return true
        case let (.some(record), .some(file)):
            return file.mode == .file && file.video == nil && file.videoCover == nil && file.metadata == nil &&
                record.attachment.name.utf8.elementsEqual(file.name.utf8) && record.plaintextByteCount == file.size &&
                (try? TelegramUploadFileIO.validateOwnedStage(file)) != nil
        default: return false
        }
    }

    func payload(for presentation: TelegramUploadPresentation) -> ArchiveFileRecord? {
        guard presentation != .archive else { return nil }
        return presentation == .file && (file.attachment.kind == "photo" || metadata?.gif != nil) ? originalFile : file
    }

    static func isDurable(_ file: ArchiveFileRecord) -> Bool {
        if file.state == .stored { return true }
        guard file.state == .local, case .some(.outgoing) = file.purpose else { return false }
        return true
    }
    static func validRecord(_ file: ArchiveFileRecord, identity: MessageArchiveIdentity, attachmentID: String) -> Bool {
        isDurable(file) && file.id != TelegramPendingUploadDraft.zeroUUID && file.identity == identity &&
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
    public let sourceFacts: TelegramUploadSourceFacts?
    public init(id: UUID, file: TelegramUploadFile, originalFile: TelegramUploadFile? = nil, sourceFacts: TelegramUploadSourceFacts? = nil) {
        self.id = id; self.file = file; self.originalFile = originalFile; self.sourceFacts = sourceFacts
    }
    var rawSource: TelegramUploadFile {
        let raw = originalFile ?? file
        return TelegramUploadFile(id: raw.id, name: raw.name, size: raw.size, mode: .file, pixelWidth: nil, pixelHeight: nil,
            url: raw.url, directory: raw.directory)
    }
    func verifySourceFacts() async throws {
        guard let facts = sourceFacts else { return }
        guard facts.isValid, facts.itemID == id, facts.role == (originalFile == nil ? .prepared : .original),
              try await TelegramUploadSourceFactsIO.inspect(itemID: id, raw: rawSource, role: facts.role, metadata: file.metadata) == facts else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
    }
    static func allowsMedia(_ items: [Self], rules: TelegramUploadMediaRules = .legacy) -> Bool {
        guard items.allSatisfy({ $0.file.mode != .photo || $0.originalFile != nil }) else { return false }
        return rules.allowsMedia(hasVisual: items.contains(where: { $0.file.mode != .file }), facts: items.map(\.sourceFacts))
    }
    func verifyGIFPair() async throws {
        guard let gif = file.metadata?.gif else { return }
        guard file.mode == .video, let originalFile, originalFile.mode == .file,
              originalFile.metadata == nil, originalFile.video == nil, originalFile.videoCover == nil,
              originalFile.id != file.id,
              file.name == telegramAttachmentName((originalFile.name as NSString).deletingPathExtension + ".mp4") else {
            throw TelegramUploadFileError.invalidGIF
        }
        try TelegramUploadFileIO.validateMetadata(file)
        guard try await TelegramUploadGIFIO.inspect(originalFile, expectedPlaintextSHA256: gif.sourceSHA256) == gif.info else {
            throw TelegramUploadFileError.invalidGIF
        }
    }
    public func presented(as presentation: TelegramUploadPresentation) -> Self? {
        guard presentation != .archive else { return nil }
        guard presentation == .file else { return self }
        guard file.metadata?.roundVideo == nil else { return nil }
        if file.mode == .photo || file.metadata?.gif != nil {
            guard let originalFile else { return nil }
            let projected = TelegramUploadFile(id: originalFile.id, name: originalFile.name, size: originalFile.size,
                mode: .file, pixelWidth: nil, pixelHeight: nil, url: originalFile.url, directory: originalFile.directory,
                metadata: file.metadata)
            return .init(id: id, file: projected, originalFile: originalFile, sourceFacts: sourceFacts)
        }
        return .init(id: id, file: TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: file.url, directory: file.directory, metadata: file.metadata), originalFile: originalFile, sourceFacts: sourceFacts)
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
