import Foundation
import MakoshCore
import UniformTypeIdentifiers

/// Presentation changes select an existing resource; they never rename JPEG bytes into an original.
public enum TelegramUploadPresentation: String, Codable, Equatable, Sendable {
    case media, file

    func allowsGrouping(_ files: [(name: String, isVisual: Bool)]) -> Bool {
        guard !files.isEmpty, !files.contains(where: { ($0.name as NSString).pathExtension.lowercased() == "webp" }),
              self != .media || files.allSatisfy(\.isVisual) else { return false }
        let audio = files.map { UTType(filenameExtension: ($0.name as NSString).pathExtension)?.conforms(to: .audio) == true }
        return !audio.contains(true) || audio.allSatisfy { $0 }
    }

    func allowsGrouping(_ files: [(name: String, isVisual: Bool, metadata: TelegramUploadMetadata?)]) -> Bool {
        if files.contains(where: { $0.metadata?.voice != nil }) { return false }
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

    init(id: UUID, file: ArchiveFileRecord, video: TelegramUploadVideoMetadata? = nil,
         videoCover: TelegramPendingUploadVideoCover? = nil, originalFile: ArchiveFileRecord? = nil,
         metadata: TelegramUploadMetadata? = nil) {
        self.id = id; self.file = file; self.video = video; self.videoCover = videoCover; self.originalFile = originalFile
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, file, video, videoCover, originalFile, metadata }
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
        guard metadata == nil || (metadata?.gif != nil
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
            (metadata.map { value in
                value.gif != nil ? validGIFPair : file.attachment.kind == "file" && video == nil && videoCover == nil && originalFile == nil && value.isValid
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
        presentation == .file && (file.attachment.kind == "photo" || metadata?.gif != nil) ? originalFile : file
    }

    static func isDurable(_ file: ArchiveFileRecord) -> Bool {
        if file.state == .stored { return true }
        guard file.state == .local, case .some(.outgoing) = file.purpose else { return false }
        return true
    }
    private static func validRecord(_ file: ArchiveFileRecord, identity: MessageArchiveIdentity, attachmentID: String) -> Bool {
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
    public init(id: UUID, file: TelegramUploadFile, originalFile: TelegramUploadFile? = nil) {
        self.id = id; self.file = file; self.originalFile = originalFile
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
        guard presentation == .file else { return self }
        if file.mode == .photo || file.metadata?.gif != nil {
            guard let originalFile else { return nil }
            let projected = TelegramUploadFile(id: originalFile.id, name: originalFile.name, size: originalFile.size,
                mode: .file, pixelWidth: nil, pixelHeight: nil, url: originalFile.url, directory: originalFile.directory,
                metadata: file.metadata)
            return .init(id: id, file: projected, originalFile: originalFile)
        }
        return .init(id: id, file: TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: file.url, directory: file.directory, metadata: file.metadata), originalFile: originalFile)
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
