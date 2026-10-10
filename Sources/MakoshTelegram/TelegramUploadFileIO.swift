import Foundation
import Darwin
import ImageIO
import CoreGraphics

public enum TelegramUploadMode: Equatable, Sendable { case file, photo }

public struct TelegramUploadFile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let size: Int64
    public let mode: TelegramUploadMode
    public let pixelWidth: Int32?
    public let pixelHeight: Int32?
    let url: URL
    let directory: URL
}

public enum TelegramUploadFileError: LocalizedError, Equatable {
    case unavailable, tooLarge, invalidImage, stagingFailed
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Выбранный файл недоступен или изменён. Выберите его снова."
        case .tooLarge: "Файл превышает ограничения подготовки вложения."
        case .invalidImage: "Не удалось подготовить фотографию. Можно отправить оригинал как файл."
        case .stagingFailed: "Не удалось подготовить временную копию вложения. Проверьте свободное место и доступ."
        }
    }
}

public enum TelegramUploadFileIO {
    public static func stage(_ source: URL, mode: TelegramUploadMode) async throws -> TelegramUploadFile {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try prepare(source, mode: mode) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Decode only our normalized photo stage; UI never receives its private URL.
    public static func preview(_ file: TelegramUploadFile) async throws -> TelegramImagePreview {
        try Task.checkCancellation()
        let expected = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + file.id.uuidString, isDirectory: true)
        guard file.mode == .photo, file.directory.isFileURL, file.url.isFileURL,
              file.directory.standardizedFileURL == expected.standardizedFileURL,
              file.url.standardizedFileURL == expected.appendingPathComponent("payload-" + file.id.uuidString).standardizedFileURL else {
            throw TelegramUploadFileError.unavailable
        }
        var info = stat()
        guard lstat(file.directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw TelegramUploadFileError.unavailable }
        return try await TelegramDownloadedFileIO.image(source: file.url, expectedSize: file.size)
    }

    static func discard(_ file: TelegramUploadFile) throws {
        let expected = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + file.id.uuidString, isDirectory: true)
        guard file.directory.standardizedFileURL == expected.standardizedFileURL,
              file.url.standardizedFileURL == expected.appendingPathComponent("payload-" + file.id.uuidString).standardizedFileURL else {
            throw TelegramUploadFileError.stagingFailed
        }
        var info = stat()
        if lstat(file.directory.path, &info) != 0 {
            if errno == ENOENT { return }
            throw TelegramUploadFileError.stagingFailed
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw TelegramUploadFileError.stagingFailed }
        do { try FileManager.default.removeItem(at: file.directory) }
        catch { throw TelegramUploadFileError.stagingFailed }
    }

    private static func prepare(_ source: URL, mode: TelegramUploadMode) throws -> TelegramUploadFile {
        try Task.checkCancellation()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL, !source.path.utf8.contains(0) else { throw TelegramUploadFileError.unavailable }
        let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(input) }
        var original = stat()
        guard fstat(input, &original) == 0, original.st_mode & S_IFMT == S_IFREG, original.st_size >= 0 else {
            throw TelegramUploadFileError.unavailable
        }
        let cap: Int64 = mode == .file ? 4 * 1024 * 1024 * 1024 : 20 * 1024 * 1024
        guard original.st_size <= cap else { throw TelegramUploadFileError.tooLarge }
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + id.uuidString, isDirectory: true)
        guard Darwin.mkdir(directory.path, 0o700) == 0 else { throw TelegramUploadFileError.stagingFailed }
        let url = directory.appendingPathComponent("payload-" + id.uuidString)
        let partial = directory.appendingPathComponent("partial-" + id.uuidString)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        guard Darwin.chmod(directory.path, 0o700) == 0 else { throw TelegramUploadFileError.stagingFailed }
        let output = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw TelegramUploadFileError.stagingFailed }
        defer { Darwin.close(output) }
        guard fchmod(output, 0o600) == 0 else { throw TelegramUploadFileError.stagingFailed }
        var width: Int32?
        var height: Int32?
        let size: Int64
        if mode == .file {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1024 * 1024, alignment: 16)
            defer { buffer.deallocate() }
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(input, buffer, 1024 * 1024)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw TelegramUploadFileError.unavailable }
                if count == 0 { break }
                copied += Int64(count)
                guard copied <= cap else { throw TelegramUploadFileError.tooLarge }
                guard copied <= original.st_size else { throw TelegramUploadFileError.unavailable }
                try writeAll(output, bytes: buffer, count: count)
            }
            guard copied == original.st_size else { throw TelegramUploadFileError.unavailable }
            size = copied
        } else {
            guard original.st_size > 0 else { throw TelegramUploadFileError.invalidImage }
            var data = Data(count: Int(original.st_size))
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let count = Darwin.read(input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw TelegramUploadFileError.unavailable }
                    offset += count
                }
            }
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let sourceWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
                  let sourceHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
                  sourceWidth > 0, sourceHeight > 0 else { throw TelegramUploadFileError.invalidImage }
            guard sourceWidth <= 8192, sourceHeight <= 8192, sourceWidth * sourceHeight <= 40_000_000 else {
                throw TelegramUploadFileError.tooLarge
            }
            try Task.checkCancellation()
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2560,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                throw TelegramUploadFileError.invalidImage
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else {
                throw TelegramUploadFileError.stagingFailed
            }
            // Add only decoded pixels and explicit encoding quality, never source metadata.
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination), encoded.length > 0 else { throw TelegramUploadFileError.invalidImage }
            try Task.checkCancellation()
            try writeAll(output, bytes: encoded.bytes, count: encoded.length)
            size = Int64(encoded.length)
            width = Int32(image.width); height = Int32(image.height)
        }
        var final = stat()
        guard fstat(input, &final) == 0, final.st_size == original.st_size,
              final.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else { throw TelegramUploadFileError.unavailable }
        try Task.checkCancellation()
        guard fsync(output) == 0, Darwin.rename(partial.path, url.path) == 0 else { throw TelegramUploadFileError.stagingFailed }
        let base = telegramAttachmentName(source.lastPathComponent)
        let name = mode == .photo ? telegramAttachmentName((base as NSString).deletingPathExtension + ".jpg") : base
        let result = TelegramUploadFile(id: id, name: name, size: size, mode: mode,
            pixelWidth: width, pixelHeight: height, url: url, directory: directory)
        success = true
        return result
    }

    private static func writeAll(_ fd: Int32, bytes: UnsafeRawPointer, count: Int) throws {
        var written = 0
        while written < count {
            try Task.checkCancellation()
            let result = Darwin.write(fd, bytes.advanced(by: written), min(count - written, 1024 * 1024))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw TelegramUploadFileError.stagingFailed }
            written += result
        }
    }
}
