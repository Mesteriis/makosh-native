import Foundation
import Darwin
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum TelegramUploadSourceFactsIO {
    static func inspect(itemID: UUID, raw: TelegramUploadFile, role: TelegramUploadSourceFacts.Role,
                        metadata: TelegramUploadMetadata? = nil) async throws -> TelegramUploadSourceFacts {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try await inspectOwned(itemID: itemID, raw: raw, role: role, metadata: metadata)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    /// Selection uses the original display name; native payload MIME is established separately from bytes.
    static func selectionMIME(for name: String) -> String {
        let suffix = (telegramAttachmentName(name) as NSString).pathExtension.lowercased()
        // Small independently authored compatibility aliases, not the upstream MIME resource.
        switch suffix {
        case "mov": return "video/mov"
        case "m4v": return "video/m4v"
        case "mkv": return "video/mkv"
        case "ogg", "opus": return "audio/ogg"
        case "mp3": return "audio/mpeg3"
        case "webp": return "image/webp"
        case "bin": return "application/x-macbinary"
        default:
            guard let mime = UTType(filenameExtension: suffix)?.preferredMIMEType?.lowercased(),
                  TelegramUploadSourceFacts.isValidMIME(mime) else { return "application/octet-stream" }
            return mime
        }
    }

    private static func inspectOwned(itemID: UUID, raw: TelegramUploadFile, role: TelegramUploadSourceFacts.Role,
                                     metadata: TelegramUploadMetadata?) async throws -> TelegramUploadSourceFacts {
        try Task.checkCancellation()
        guard raw.mode == .file, raw.metadata == nil, raw.video == nil, raw.videoCover == nil,
              raw.pixelWidth == nil, raw.pixelHeight == nil, raw.name == telegramAttachmentName(raw.name),
              metadata?.voice == nil, metadata?.roundVideo == nil,
              metadata?.isValid ?? true else { throw TelegramUploadFileError.unavailable }
        try TelegramUploadFileIO.validateOwnedStage(raw)
        let fd = Darwin.open(raw.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == getuid(), original.st_mode & 0o777 == 0o600,
              original.st_size == raw.size else { throw TelegramUploadFileError.unavailable }
        let digest = try hash(fd: fd, size: raw.size)
        let mime = selectionMIME(for: raw.name)
        let image: TelegramUploadSourceFacts.ImageProbe
        if mime.hasPrefix("image") {
            image = raw.size > 0 && raw.size <= 20 * 1024 * 1024
                ? try logicalImage(read(fd: fd, count: Int(raw.size), offset: 0)) : .rejected
        } else { image = .notImage }
        try TelegramUploadVideoIO.validateSnapshot(raw, fd: fd, original: original)
        let grouping: TelegramUploadSourceFacts.GroupingProbe
        if case let .audio(expected) = metadata {
            guard try await TelegramUploadAudioIO.inspect(raw) == expected else { throw TelegramUploadFileError.invalidAudio }
            grouping = .music
        } else if mime.hasPrefix("audio/") {
            do {
                _ = try await TelegramUploadAudioIO.inspect(raw)
                grouping = .music
            } catch TelegramUploadFileError.invalidAudio {
                // A selected suffix is a hint; failed byte probing cannot invent music/voice intent.
                grouping = .ordinary
            }
        } else {
            // Ordinary source URL attributes use inCollage:true, suppressing Animated.
            grouping = .ordinary
        }
        try Task.checkCancellation()
        try TelegramUploadVideoIO.validateSnapshot(raw, fd: fd, original: original)
        let result = TelegramUploadSourceFacts(itemID: itemID, role: role, name: raw.name, byteCount: raw.size,
            plaintextSHA256: digest, selectionMIME: mime, image: image, grouping: grouping)
        guard result.isValid else { throw TelegramUploadFileError.unavailable }
        return result
    }

    private static func hash(fd: Int32, size: Int64) throws -> String {
        var digest = SHA256(), position: Int64 = 0
        while position < size {
            try Task.checkCancellation()
            let count = Int(min(1_048_576, size - position))
            digest.update(data: try read(fd: fd, count: count, offset: position))
            position += Int64(count)
        }
        try Task.checkCancellation()
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func read(fd: Int32, count: Int, offset: Int64) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var position = 0
            while position < count {
                try Task.checkCancellation()
                let actual = pread(fd, bytes.baseAddress!.advanced(by: position), min(count - position, 1_048_576), offset + Int64(position))
                if actual < 0 && errno == EINTR { continue }
                guard actual > 0 else { throw TelegramUploadFileError.unavailable }
                position += actual
            }
        }
        return data
    }

    /// Logical option facts include GIF/WebP; they do not promise static-photo or native send eligibility.
    private static func logicalImage(_ data: Data) throws -> TelegramUploadSourceFacts.ImageProbe {
        try autoreleasepool {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String), type.conforms(to: .image),
                  CGImageSourceGetStatus(source) == .statusComplete else { return .rejected }
            let count = CGImageSourceGetCount(source)
            guard count > 0, count <= 256,
                  let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return .rejected }
            let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
            var canvas = dimensions(global ?? first) ?? dimensions(first)
            // Container canvas must be bounded before NSImage sees partial-frame animations.
            if data.count >= 13, data.starts(with: Data("GIF8".utf8)) {
                canvas = (Double(Int(data[6]) | Int(data[7]) << 8), Double(Int(data[8]) | Int(data[9]) << 8))
            } else if data.count >= 30, data.starts(with: Data("RIFF".utf8)),
                      data[8..<12] == Data("WEBP".utf8), data[12..<16] == Data("VP8X".utf8) {
                let width = 1 + Int(data[24]) + (Int(data[25]) << 8) + (Int(data[26]) << 16)
                let height = 1 + Int(data[27]) + (Int(data[28]) << 8) + (Int(data[29]) << 16)
                canvas = (Double(width), Double(height))
            }
            guard let (width, height) = canvas, safeDimensions(width, height),
                  width * height * Double(count) <= 256_000_000 else { return .rejected }
            let thumbnailOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true]
            for index in 0..<count {
                try Task.checkCancellation()
                guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let (frameWidth, frameHeight) = dimensions(properties), safeDimensions(frameWidth, frameHeight),
                      frameWidth <= width, frameHeight <= height,
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions as CFDictionary),
                      thumbnail.width > 0, thumbnail.height > 0, thumbnail.width <= 256, thumbnail.height <= 256 else { return .rejected }
            }
            try Task.checkCancellation()
            guard let image = NSImage(data: data) else { return .rejected }
            let logical = image.size
            guard logical.width.isFinite, logical.height.isFinite, logical.width > 0, logical.height > 0 else { return .rejected }
            try Task.checkCancellation()
            return .decoded(width: logical.width, height: logical.height)
        }
    }

    private static func dimensions(_ properties: [CFString: Any]) -> (Double, Double)? {
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        return (width, height)
    }

    private static func safeDimensions(_ width: Double, _ height: Double) -> Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 40_000_000
    }
}
