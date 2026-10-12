import Foundation
import Darwin
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum TelegramUploadPhotoEligibility {
    /// SenderController's payload decision uses transformed photo pixels. Source options use separate logical facts.
    static func canPrepare(_ raw: TelegramUploadFile, photoSize: TelegramUploadPhotoSize = .standard,
                           allowsSelectedWebPPhoto: Bool = false) async throws -> Bool {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try inspect(raw, photoSize: photoSize, allowsSelectedWebPPhoto: allowsSelectedWebPPhoto)
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    private static func inspect(_ raw: TelegramUploadFile, photoSize: TelegramUploadPhotoSize,
                                allowsSelectedWebPPhoto: Bool) throws -> Bool {
        try Task.checkCancellation()
        guard raw.mode == .file else { throw TelegramUploadFileError.unavailable }
        try TelegramUploadFileIO.validateOwnedStage(raw)
        guard raw.size > 0, raw.size <= 20 * 1024 * 1024 else { return false }
        let fd = Darwin.open(raw.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == getuid(), original.st_mode & 0o777 == 0o600,
              original.st_size == raw.size else { throw TelegramUploadFileError.unavailable }
        var data = Data(count: Int(raw.size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), min(bytes.count - offset, 1024 * 1024))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TelegramUploadFileError.unavailable }
                offset += count
            }
        }
        let result = try eligibleImage(data, photoSize: photoSize, allowsSelectedWebPPhoto: allowsSelectedWebPPhoto)
        try TelegramUploadFileIO.validateOwnedStage(raw)
        var final = stat(), current = stat()
        guard fstat(fd, &final) == 0, lstat(raw.url.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino,
              final.st_size == original.st_size,
              final.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw TelegramUploadFileError.unavailable
        }
        try Task.checkCancellation()
        return result
    }

    private static func eligibleImage(_ data: Data, photoSize: TelegramUploadPhotoSize,
                                      allowsSelectedWebPPhoto: Bool) throws -> Bool {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              type.conforms(to: .image), !type.conforms(to: .gif),
              allowsSelectedWebPPhoto || !(UTType(filenameExtension: "webp").map { type.conforms(to: $0) } ?? false),
              CGImageSourceGetCount(source) == 1 || (allowsSelectedWebPPhoto &&
                  (UTType(filenameExtension: "webp").map { type.conforms(to: $0) } ?? false) && CGImageSourceGetCount(source) > 0),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 40_000_000 else { return false }
        let maximum = photoSize.maximumPixelSize
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        try Task.checkCancellation()
        guard let image, image.width > 0, image.height >= 40,
              image.width <= maximum, image.height <= maximum else { return false }
        return Double(image.width) / 10 <= Double(image.height)
    }
}
