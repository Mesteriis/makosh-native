import Foundation
import CryptoKit
import Darwin
import ImageIO

public struct TelegramUploadVideoCover: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let width: Int32
    public let height: Int32
    public let size: Int64
    let name: String
    let url: URL
    let directory: URL
    let sha256: String
    var imageFile: TelegramUploadFile {
        TelegramUploadFile(id: id, name: name, size: size, mode: .photo,
            pixelWidth: width, pixelHeight: height, url: url, directory: directory)
    }
}

public struct TelegramUploadVideoCoverSelection: Identifiable, Sendable {
    public var id: UUID { file.id }
    public let preview: TelegramImagePreview
    let file: TelegramUploadFile
}

public enum TelegramUploadVideoCoverIO {
    @concurrent public static func openSelection(_ source: URL) async throws -> TelegramUploadVideoCoverSelection {
        let file = try await TelegramUploadFileIO.stageImageSource(source)
        do {
            try TelegramUploadFileIO.validateOwnedStage(file)
            let preview = try await TelegramDownloadedFileIO.image(source: file.url, expectedSize: file.size,
                maximumBytes: 20 * 1024 * 1024, maximumDimension: 8192, maximumPixels: 40_000_000, thumbnailPixelSize: 8192)
            try Task.checkCancellation()
            return TelegramUploadVideoCoverSelection(preview: preview, file: file)
        } catch {
            try? TelegramUploadFileIO.discard(file)
            throw error
        }
    }
    public static func discardSelection(_ selection: TelegramUploadVideoCoverSelection) throws {
        try TelegramUploadFileIO.discard(selection.file)
    }
    @concurrent public static func discardSelectionInBackground(_ selection: TelegramUploadVideoCoverSelection) async throws {
        // Owned temporary-file cleanup must finish even after editor cancellation.
        try discardSelection(selection)
    }
    public static func discardCover(_ cover: TelegramUploadVideoCover) throws {
        try TelegramUploadFileIO.discard(cover.imageFile)
    }
    @concurrent public static func stage(_ selection: TelegramUploadVideoCoverSelection, crop: CGRect,
                             transform: TelegramUploadVideoCoverTransform = .init(),
                             painting: TelegramUploadVideoCoverPainting = .init(),
                             images: TelegramUploadVideoCoverImages = .init()) async throws -> TelegramUploadVideoCover {
        try TelegramUploadFileIO.validateOwnedStage(selection.file)
        guard let digest = selection.preview.originalSHA256 else { throw TelegramUploadFileError.unavailable }
        return try await stagedCover(selection.file.url, crop: crop, expectedSHA256: digest, transform: transform, painting: painting, images: images)
    }
    @concurrent public static func stage(_ source: URL, crop: CGRect) async throws -> TelegramUploadVideoCover {
        try await stagedCover(source, crop: crop, expectedSHA256: nil)
    }
    private static func stagedCover(_ source: URL, crop: CGRect, expectedSHA256: String?,
                                    transform: TelegramUploadVideoCoverTransform = .init(),
                                    painting: TelegramUploadVideoCoverPainting = .init(),
                             images: TelegramUploadVideoCoverImages = .init()) async throws -> TelegramUploadVideoCover {
        let file = try await TelegramUploadFileIO.stageVideoCover(source, crop: crop, expectedSHA256: expectedSHA256, transform: transform, painting: painting, images: images)
        do {
            try Task.checkCancellation()
            guard let width = file.pixelWidth, let height = file.pixelHeight,
                  width > 0, height > 0, width <= 320, height <= 320, file.size > 0, file.size <= 1_048_576 else {
                throw TelegramUploadFileError.invalidImage
            }
            let bytes = try imageBytes(file)
            try Task.checkCancellation()
            return TelegramUploadVideoCover(id: file.id, width: width, height: height, size: file.size,
                name: file.name, url: file.url, directory: file.directory,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        } catch {
            try? TelegramUploadFileIO.discard(file)
            throw error
        }
    }
    public static func preview(_ cover: TelegramUploadVideoCover) async throws -> TelegramImagePreview {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            let bytes = try validatedBytes(cover)
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw TelegramUploadFileError.invalidImage
            }
            try Task.checkCancellation()
            return TelegramImagePreview(image: image, originalExtension: "jpg", originalSHA256: cover.sha256)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func validatedBytes(_ cover: TelegramUploadVideoCover) throws -> Data {
        let bytes = try imageBytes(cover.imageFile)
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == cover.sha256 else {
            throw TelegramUploadFileError.unavailable
        }
        return bytes
    }

    private static func imageBytes(_ file: TelegramUploadFile) throws -> Data {
        try Task.checkCancellation()
        guard let width = file.pixelWidth, let height = file.pixelHeight, width > 0, height > 0,
              width <= 320, height <= 320, file.size > 0, file.size <= 1_048_576 else {
            throw TelegramUploadFileError.invalidImage
        }
        try TelegramUploadFileIO.validateOwnedStage(file)
        let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == getuid(), original.st_mode & 0o777 == 0o600, original.st_size == file.size else {
            throw TelegramUploadFileError.unavailable
        }
        var bytes = Data(count: Int(file.size))
        try bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw TelegramUploadFileError.unavailable }
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.read(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TelegramUploadFileError.unavailable }
                offset += count
            }
        }
        var final = stat(), path = stat()
        guard fstat(fd, &final) == 0, lstat(file.url.path, &path) == 0,
              path.st_dev == original.st_dev, path.st_ino == original.st_ino,
              path.st_mode & S_IFMT == S_IFREG, path.st_uid == original.st_uid,
              path.st_mode & 0o777 == 0o600, path.st_size == original.st_size,
              final.st_size == original.st_size, final.st_mode == original.st_mode,
              final.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else { throw TelegramUploadFileError.unavailable }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int32Value == width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int32Value == height,
              properties[kCGImagePropertyOrientation] == nil || (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 1 else {
            throw TelegramUploadFileError.invalidImage
        }
        try Task.checkCancellation()
        return bytes
    }
}
