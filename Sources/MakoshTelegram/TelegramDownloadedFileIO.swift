import Foundation
import Darwin
import ImageIO
import CoreGraphics

public enum TelegramFileError: LocalizedError, Equatable {
    case unavailable, copyFailed, previewLimit, invalidImage
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Загруженный файл недоступен или изменён. Повторите загрузку."
        case .copyFailed: "Не удалось сохранить файл. Проверьте выбранную папку."
        case .previewLimit: "Изображение превышает ограничения предпросмотра. Его можно сохранить как файл."
        case .invalidImage: "Не удалось прочитать изображение. Его можно сохранить как файл."
        }
    }
}

/// CGImage is immutable; this value crosses from the bounded decoder worker to UI.
public struct TelegramImagePreview: @unchecked Sendable {
    public let image: CGImage
}

public enum TelegramDownloadedFileIO {
    public static func copy(source: URL, expectedSize: Int64, destination: URL) async throws {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try copyFile(source: source, expectedSize: expectedSize, destination: destination)
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    public static func image(source: URL, expectedSize: Int64) async throws -> TelegramImagePreview {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            guard expectedSize > 0, expectedSize <= 20 * 1_024 * 1_024 else { throw TelegramFileError.previewLimit }
            let fd = try openSource(source, expectedSize: expectedSize)
            defer { Darwin.close(fd) }
            var bytes = Data(count: Int(expectedSize))
            try bytes.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try Task.checkCancellation()
                    let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw TelegramFileError.unavailable }
                    offset += count
                }
            }
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
                  width > 0, height > 0 else { throw TelegramFileError.invalidImage }
            guard width <= 8_192, height <= 8_192, width * height <= 40_000_000 else { throw TelegramFileError.previewLimit }
            try Task.checkCancellation()
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_280, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw TelegramFileError.invalidImage }
            try Task.checkCancellation()
            return TelegramImagePreview(image: image)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func openSource(_ source: URL, expectedSize: Int64) throws -> Int32 {
        guard source.isFileURL, !source.path.utf8.contains(0), expectedSize >= 0 else { throw TelegramFileError.unavailable }
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramFileError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == expectedSize else {
            Darwin.close(fd)
            throw TelegramFileError.unavailable
        }
        return fd
    }

    private static func copyFile(source: URL, expectedSize: Int64, destination: URL) throws {
        let input = try openSource(source, expectedSize: expectedSize)
        defer { Darwin.close(input) }
        guard destination.isFileURL, !destination.path.utf8.contains(0) else { throw TelegramFileError.copyFailed }
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw TelegramFileError.copyFailed }
        let parent = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw TelegramFileError.copyFailed }
        defer { Darwin.close(parent) }
        let temporary = ".makosh-export-" + UUID().uuidString
        let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw TelegramFileError.copyFailed }
        defer { Darwin.close(output); unlinkat(parent, temporary, 0) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024 * 1_024, alignment: 16)
        defer { buffer.deallocate() }
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(input, buffer, 1_024 * 1_024)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw TelegramFileError.copyFailed }
            if count == 0 { break }
            copied += Int64(count)
            guard copied <= expectedSize else { throw TelegramFileError.unavailable }
            var written = 0
            while written < count {
                try Task.checkCancellation()
                let size = Darwin.write(output, buffer.advanced(by: written), count - written)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw TelegramFileError.copyFailed }
                written += size
            }
        }
        guard copied == expectedSize else { throw TelegramFileError.unavailable }
        try Task.checkCancellation()
        // Do not follow/replace a destination symlink, directory or special file.
        var existing = stat()
        if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw TelegramFileError.copyFailed }
            var original = stat()
            guard fstat(input, &original) == 0,
                  existing.st_dev != original.st_dev || existing.st_ino != original.st_ino else { throw TelegramFileError.copyFailed }
        } else if errno != ENOENT { throw TelegramFileError.copyFailed }
        guard fsync(output) == 0 else { throw TelegramFileError.copyFailed }
        try Task.checkCancellation()
        guard renameat(parent, temporary, parent, name) == 0 else { throw TelegramFileError.copyFailed }
    }
}
