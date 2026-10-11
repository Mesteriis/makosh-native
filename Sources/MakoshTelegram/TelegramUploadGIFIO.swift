import Foundation
import Darwin
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

struct TelegramUploadGIFInfo: Equatable, Sendable {
    let width: Int32
    let height: Int32
    let frameDurations: [Float]
}

enum TelegramUploadGIFError: Error, Equatable { case invalidGIF }

enum TelegramUploadGIFIO {
    static func inspect(_ raw: TelegramUploadFile) async throws -> TelegramUploadGIFInfo? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            let snapshot = try GIFSnapshot(raw)
            guard let data = try snapshot.gifData() else { return nil as TelegramUploadGIFInfo? }
            let info = try facts(data)
            try snapshot.validate()
            try Task.checkCancellation()
            return info
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    static func convert(_ raw: TelegramUploadFile, expected: TelegramUploadGIFInfo,
                        expectedPlaintextSHA256: String? = nil) async throws -> TelegramUploadFile {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            let snapshot = try GIFSnapshot(raw)
            guard let data = try snapshot.gifData() else { throw TelegramUploadGIFError.invalidGIF }
            if let digest = expectedPlaintextSHA256 {
                guard digest.utf8.count == 64,
                      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                    throw TelegramUploadFileError.unavailable
                }
            }
            let actual = try facts(data)
            guard actual == expected else { throw TelegramUploadGIFError.invalidGIF }
            try snapshot.validate()
            let output = try await TelegramUploadGIFConversion.write(data, info: actual, name: raw.name)
            do {
                try Task.checkCancellation()
                try snapshot.validate()
                return output
            } catch {
                try? TelegramUploadFileIO.discard(output)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            let output = try await worker.value
            do {
                try Task.checkCancellation()
                return output
            } catch {
                try? TelegramUploadFileIO.discard(output)
                throw error
            }
        } onCancel: { worker.cancel() }
    }

    /// The global GIF canvas bounds decoding even when a frame updates only a patch.
    /// Require full-canvas native images instead of stretching partial frames.
    /// Synthetic pixel readback tests cover placement and the retained background.
    private static func facts(_ data: Data) throws -> TelegramUploadGIFInfo {
        try Task.checkCancellation()
        guard data.count >= 13, data.count <= 20 * 1024 * 1024 else {
            throw TelegramUploadGIFError.invalidGIF
        }
        let width = Int(data[6]) | Int(data[7]) << 8
        let height = Int(data[8]) | Int(data[9]) << 8
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 16_000_000,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw TelegramUploadGIFError.invalidGIF
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 256, width * height * count <= 256_000_000 else {
            throw TelegramUploadGIFError.invalidGIF
        }
        var durations: [Float] = []
        var total: Double = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let delay: Float = try autoreleasepool {
                guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      pixelWidth > 0, pixelHeight > 0, pixelWidth <= width, pixelHeight <= height else {
                    throw TelegramUploadGIFError.invalidGIF
                }
                let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let number = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)
                var delay = number?.floatValue ?? Float(0.1)
                guard delay.isFinite, delay >= 0 else { throw TelegramUploadGIFError.invalidGIF }
                if delay < Float(0.011) { delay = 0.1 }
                guard let image = CGImageSourceCreateImageAtIndex(source, index,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      image.width == width, image.height == height,
                      CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
                    throw TelegramUploadGIFError.invalidGIF
                }
                return delay
            }
            total += Double(delay)
            guard total.isFinite, total <= 600 else { throw TelegramUploadGIFError.invalidGIF }
            durations.append(delay)
        }
        try Task.checkCancellation()
        return .init(width: Int32(width), height: Int32(height), frameDurations: durations)
    }
}

/// Keep the original descriptor alive until every native conversion and output
/// validation completes. Only its bounded immutable bytes enter ImageIO.
private final class GIFSnapshot {
    let raw: TelegramUploadFile
    let fd: Int32
    let original: stat

    init(_ raw: TelegramUploadFile) throws {
        try Task.checkCancellation()
        try TelegramUploadFileIO.validateOwnedStage(raw)
        guard raw.mode == .file, raw.size >= 0 else { throw TelegramUploadFileError.unavailable }
        let input = Darwin.open(raw.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw TelegramUploadFileError.unavailable }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_size == raw.size else {
            Darwin.close(input)
            throw TelegramUploadFileError.unavailable
        }
        self.raw = raw
        self.fd = input
        self.original = info
    }

    deinit { Darwin.close(fd) }

    func validate() throws {
        try TelegramUploadVideoIO.validateSnapshot(raw, fd: fd, original: original)
    }

    func gifData() throws -> Data? {
        let header = try read(Int(min(raw.size, 6)))
        guard header.starts(with: Data("GIF".utf8)) else {
            try validate()
            return nil
        }
        guard header == Data("GIF87a".utf8) || header == Data("GIF89a".utf8),
              raw.size <= 20 * 1024 * 1024 else { throw TelegramUploadGIFError.invalidGIF }
        let data = try read(Int(raw.size))
        var extra: UInt8 = 0
        var count: Int
        repeat { count = Darwin.pread(fd, &extra, 1, off_t(raw.size)) } while count < 0 && errno == EINTR
        guard count == 0 else { throw TelegramUploadFileError.unavailable }
        try validate()
        return data
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try Task.checkCancellation()
                let read = Darwin.pread(fd, bytes.baseAddress!.advanced(by: offset),
                    min(count - offset, 1024 * 1024), off_t(offset))
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw TelegramUploadFileError.unavailable }
                offset += read
            }
        }
        try Task.checkCancellation()
        return data
    }
}
