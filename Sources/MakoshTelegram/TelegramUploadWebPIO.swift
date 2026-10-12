import Foundation
import Darwin
import ImageIO
import CoreGraphics
import CryptoKit

enum TelegramUploadWebPIO {
    static func thumbnail(_ raw: TelegramUploadFile,
                          expectedPlaintextSHA256: String? = nil) async throws -> TelegramUploadVideoThumbnail? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try thumbnailOwned(raw, expectedPlaintextSHA256: expectedPlaintextSHA256)
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    static func inspect(_ raw: TelegramUploadFile) async throws -> TelegramUploadWebPMetadata? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try inspectOwned(raw) }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    /// Probe frozen bytes independently of a persisted descriptor or caller-supplied filename.
    private static func inspectOwned(_ raw: TelegramUploadFile) throws -> TelegramUploadWebPMetadata? {
        try withOwnedBytes(raw) { data in
            try data.map { try dimensions($0) }
        }
    }

    private static func thumbnailOwned(_ raw: TelegramUploadFile,
                                       expectedPlaintextSHA256: String?) throws -> TelegramUploadVideoThumbnail? {
        try Task.checkCancellation()
        guard case let .webP(frozen)? = raw.metadata else { return nil }
        guard frozen.isValid else { throw TelegramUploadFileError.invalidWebP }
        if let expectedPlaintextSHA256 {
            guard TelegramPendingUploadDraft.isHash(expectedPlaintextSHA256) else {
                throw TelegramUploadFileError.unavailable
            }
        }
        return try withOwnedBytes(raw) { data in
            guard let data else { throw TelegramUploadFileError.invalidWebP }
            // Bind the derivative to these exact held-fd bytes before any optional codec fallback.
            if let expectedPlaintextSHA256 {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == expectedPlaintextSHA256 else { throw TelegramUploadFileError.unavailable }
            }
            let (source, actual) = try validatedSource(data)
            guard actual == frozen else { throw TelegramUploadFileError.invalidWebP }
            try Task.checkCancellation()
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            guard image.width > 0, image.height > 0, image.width <= 320, image.height <= 320,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw TelegramUploadFileError.invalidWebP
            }
            try Task.checkCancellation()
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length > 0, output.length <= 1_048_576 else {
                return nil
            }
            try Task.checkCancellation()
            return TelegramUploadVideoThumbnail(data: output as Data,
                width: Int32(image.width), height: Int32(image.height))
        }
    }

    /// Keep the descriptor, digest and native derivative on the same bounded owned file snapshot.
    private static func withOwnedBytes<Result>(_ raw: TelegramUploadFile,
                                              body: (Data?) throws -> Result) throws -> Result {
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
            var data: Data?
            if header.count == 12, header.prefix(4) == Data("RIFF".utf8),
               header.suffix(4) == Data("WEBP".utf8) {
                let declared = (4..<8).reduce(UInt32(0)) {
                    $0 | UInt32(header[$1]) << UInt32(($1 - 4) * 8)
                }
                guard raw.size <= 20 * 1024 * 1024, UInt64(declared) + 8 == UInt64(raw.size) else {
                    throw TelegramUploadFileError.invalidWebP
                }
                var bytes = Data(count: Int(raw.size))
                bytes.replaceSubrange(0..<12, with: header)
                try read(fd, into: &bytes, startingAt: 12)
                try Task.checkCancellation()
                try TelegramUploadVideoIO.validateSnapshot(raw, fd: fd, original: original)
                data = bytes
            }
            let result = try body(data)
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
        let (source, result) = try validatedSource(data)
        // Inspect the intrinsic frame 0 dimensions lazily, then prove bounded native decoding.
        guard let frame = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              frame.width == Int(result.width), frame.height == Int(result.height) else {
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

    static func validatedSource(_ data: Data) throws -> (CGImageSource, TelegramUploadWebPMetadata) {
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
        try Task.checkCancellation()
        return (source, result)
    }

    private static func dimension(_ value: Any?) -> Int32? {
        guard let value = value as? NSNumber else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number > 0, number <= 8192, number.rounded(.towardZero) == number else { return nil }
        return Int32(number)
    }
}
