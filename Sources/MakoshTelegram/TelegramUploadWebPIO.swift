import Foundation
import Darwin
import ImageIO
import CoreGraphics

enum TelegramUploadWebPIO {
    static func inspect(_ raw: TelegramUploadFile) async throws -> TelegramUploadWebPMetadata? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try inspectOwned(raw) }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    /// Probe frozen bytes independently of a persisted descriptor or caller-supplied filename.
    private static func inspectOwned(_ raw: TelegramUploadFile) throws -> TelegramUploadWebPMetadata? {
        try Task.checkCancellation()
        guard raw.mode == .file else { throw TelegramUploadFileError.unavailable }
        try TelegramUploadFileIO.validateOwnedStage(raw)
        let fd = Darwin.open(raw.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == getuid(), original.st_mode & 0o777 == 0o600,
              original.st_size == raw.size else { throw TelegramUploadFileError.unavailable }
        do {
            // Generic documents only need a 12-byte sniff, regardless of their potentially large size.
            var header = Data(count: Int(min(12, raw.size)))
            try read(fd, into: &header)
            var result: TelegramUploadWebPMetadata?
            if header.count == 12, header.prefix(4) == Data("RIFF".utf8),
               header.suffix(4) == Data("WEBP".utf8) {
                let declared = (4..<8).reduce(UInt32(0)) {
                    $0 | UInt32(header[$1]) << UInt32(($1 - 4) * 8)
                }
                guard raw.size <= 20 * 1024 * 1024, UInt64(declared) + 8 == UInt64(raw.size) else {
                    throw TelegramUploadFileError.invalidWebP
                }
                var data = Data(count: Int(raw.size))
                data.replaceSubrange(0..<12, with: header)
                try read(fd, into: &data, startingAt: 12)
                try Task.checkCancellation()
                try TelegramUploadVideoIO.validateSnapshot(raw, fd: fd, original: original)
                result = try dimensions(data)
            }
            try Task.checkCancellation()
            try TelegramUploadVideoIO.validateSnapshot(raw, fd: fd, original: original)
            return result
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            // A changed source remains an ownership error even if it first breaks native decoding.
            try TelegramUploadVideoIO.validateSnapshot(raw, fd: fd, original: original)
            throw error
        }
    }

    private static func read(_ fd: Int32, into data: inout Data, startingAt offset: Int = 0) throws {
        try data.withUnsafeMutableBytes { bytes in
            var position = offset
            while position < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: position),
                    min(bytes.count - position, 1024 * 1024))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TelegramUploadFileError.unavailable }
                position += count
            }
        }
    }

    private static func dimensions(_ data: Data) throws -> TelegramUploadWebPMetadata {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "org.webmproject.webp",
              (1...256).contains(CGImageSourceGetCount(source)),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = dimension(properties[kCGImagePropertyPixelWidth]),
              let height = dimension(properties[kCGImagePropertyPixelHeight]) else {
            throw TelegramUploadFileError.invalidWebP
        }
        let result = TelegramUploadWebPMetadata(width: width, height: height)
        guard result.isValid else { throw TelegramUploadFileError.invalidWebP }
        if CGImageSourceGetCount(source) > 1 {
            guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
                  let webP = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any],
                  dimension(webP[kCGImagePropertyWebPCanvasPixelWidth]) == width,
                  dimension(webP[kCGImagePropertyWebPCanvasPixelHeight]) == height else {
                throw TelegramUploadFileError.invalidWebP
            }
        }
        // Inspect the intrinsic frame 0 dimensions lazily, then prove bounded native decoding.
        guard let frame = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              frame.width == Int(width), frame.height == Int(height) else {
            throw TelegramUploadFileError.invalidWebP
        }
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              thumbnail.width > 0, thumbnail.height > 0,
              thumbnail.width <= 256, thumbnail.height <= 256,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw TelegramUploadFileError.invalidWebP
        }
        try Task.checkCancellation()
        return result
    }

    private static func dimension(_ value: Any?) -> Int32? {
        guard let value = value as? NSNumber else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number > 0, number <= 8192, number.rounded(.towardZero) == number else { return nil }
        return Int32(number)
    }
}
