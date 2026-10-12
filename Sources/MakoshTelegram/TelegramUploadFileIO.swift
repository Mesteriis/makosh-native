import Foundation
import Darwin
import ImageIO
import CoreGraphics
import CryptoKit

public enum TelegramUploadMode: String, Equatable, Sendable { case file, photo, video }

public enum TelegramUploadPhotoSize: Equatable, Sendable {
    case standard, large
    public static let preferenceKey = "telegram.sendLargePhotos"
    public init(sendLargePhotos: Bool) { self = sendLargePhotos ? .large : .standard }
    var maximumPixelSize: Int { self == .large ? 2560 : 1280 }
}

public struct TelegramUploadFile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let size: Int64
    public let mode: TelegramUploadMode
    public let pixelWidth: Int32?
    public let pixelHeight: Int32?
    public let video: TelegramUploadVideoMetadata?
    public let videoCover: TelegramUploadVideoCover?
    public let metadata: TelegramUploadMetadata?
    let url: URL
    let directory: URL
    init(id: UUID, name: String, size: Int64, mode: TelegramUploadMode, pixelWidth: Int32?, pixelHeight: Int32?,
         url: URL, directory: URL, video: TelegramUploadVideoMetadata? = nil, videoCover: TelegramUploadVideoCover? = nil,
         metadata: TelegramUploadMetadata? = nil) {
        self.id = id; self.name = name; self.size = size; self.mode = mode
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.url = url; self.directory = directory; self.video = video
        self.videoCover = videoCover
        self.metadata = metadata
    }
}

public enum TelegramUploadFileError: LocalizedError, Equatable {
    case unavailable, tooLarge, invalidImage, invalidVideo, invalidAudio, invalidWebP, invalidGIF, invalidVoice, stagingFailed
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Выбранный файл недоступен или изменён. Выберите его снова."
        case .tooLarge: "Файл превышает ограничения подготовки вложения."
        case .invalidImage: "Не удалось подготовить фотографию. Можно отправить оригинал как файл."
        case .invalidVideo: "Не удалось подготовить видео. Можно отправить оригинал как файл."
        case .invalidAudio: "Не удалось проверить аудиофайл. Можно отправить оригинал как файл."
        case .invalidWebP: "Не удалось проверить WebP. Можно отправить оригинал как файл."
        case .invalidGIF: "Не удалось проверить GIF. Можно отправить оригинал как файл."
        case .invalidVoice: "Не удалось проверить запись голосового сообщения."
        case .stagingFailed: "Не удалось подготовить временную копию вложения. Проверьте свободное место и доступ."
        }
    }
}

public enum TelegramUploadFileIO {
    /// Restoration accepts both selected sizes and previously prepared large photos without transcoding.
    static let photoMaximumPixelSize = 2560
    public static func stage(_ source: URL, mode: TelegramUploadMode) async throws -> TelegramUploadFile {
        try await stage(source, mode: mode, photoSize: .standard)
    }

    public static func stage(_ source: URL, mode: TelegramUploadMode, photoSize: TelegramUploadPhotoSize) async throws -> TelegramUploadFile {
        try await stage(source, mode: mode, coverCrop: nil, photoSize: photoSize)
    }

    static func stageImageSource(_ source: URL) async throws -> TelegramUploadFile {
        try await stage(source, mode: .file, coverCrop: nil, sourceByteLimit: 20 * 1024 * 1024)
    }

    static func stageVideoCover(_ source: URL, crop: CGRect, expectedSHA256: String? = nil,
                                transform: TelegramUploadVideoCoverTransform = .init(),
                                painting: TelegramUploadVideoCoverPainting = .init(),
                                images: TelegramUploadVideoCoverImages = .init()) async throws -> TelegramUploadFile {
        guard crop.origin.x.isFinite, crop.origin.y.isFinite, crop.size.width.isFinite, crop.size.height.isFinite,
              crop.origin.x >= 0, crop.origin.y >= 0, crop.size.width > 0, crop.size.height > 0,
              crop.origin.x + crop.size.width <= 1, crop.origin.y + crop.size.height <= 1 else {
            throw TelegramUploadFileError.invalidImage
        }
        return try await stage(source, mode: .photo, coverCrop: crop, expectedCoverSHA256: expectedSHA256, coverTransform: transform, coverPainting: painting, coverImages: images)
    }

    private static func stage(_ source: URL, mode: TelegramUploadMode, coverCrop: CGRect?, expectedCoverSHA256: String? = nil,
                              sourceByteLimit: Int64? = nil, coverTransform: TelegramUploadVideoCoverTransform = .init(),
                              coverPainting: TelegramUploadVideoCoverPainting = .init(),
                              coverImages: TelegramUploadVideoCoverImages = .init(),
                              photoSize: TelegramUploadPhotoSize = .standard) async throws -> TelegramUploadFile {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            let file = try prepare(source, mode: mode, coverCrop: coverCrop, expectedCoverSHA256: expectedCoverSHA256,
                sourceByteLimit: sourceByteLimit, coverTransform: coverTransform, coverPainting: coverPainting, coverImages: coverImages, photoSize: photoSize)
            guard mode == .video else { return file }
            do {
                let info = try await TelegramUploadVideoIO.inspect(file)
                try Task.checkCancellation()
                let video = TelegramUploadVideoMetadata(width: info.width, height: info.height,
                    duration: info.duration, hasAudio: info.hasAudio, inCollage: true)
                return TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: .video,
                    pixelWidth: info.width, pixelHeight: info.height, url: file.url, directory: file.directory, video: video)
            } catch {
                try? discard(file)
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Decode only our owned photo/video stage; UI never receives its private URL.
    public static func preview(_ file: TelegramUploadFile) async throws -> TelegramImagePreview {
        try Task.checkCancellation()
        if file.mode == .video {
            if let cover = file.videoCover { return try await TelegramUploadVideoCoverIO.preview(cover) }
            return try await TelegramUploadVideoIO.poster(file)
        }
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

    static func validateOwnedStage(_ file: TelegramUploadFile) throws {
        let expected = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + file.id.uuidString, isDirectory: true)
        guard file.directory.isFileURL, file.url.isFileURL,
              file.directory.standardizedFileURL == expected.standardizedFileURL,
              file.url.standardizedFileURL == expected.appendingPathComponent("payload-" + file.id.uuidString).standardizedFileURL else { throw TelegramUploadFileError.unavailable }
        var info = stat()
        guard lstat(file.directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw TelegramUploadFileError.unavailable }
        let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_size == file.size, file.size >= 0,
              file.size <= (file.mode == .photo ? 20 * 1024 * 1024 : 4 * 1024 * 1024 * 1024) else { throw TelegramUploadFileError.unavailable }
    }

    static func restoredStage(id: UUID, name: String, size: Int64, mode: TelegramUploadMode, url: URL, directory: URL,
                              video: TelegramUploadVideoMetadata? = nil, metadata: TelegramUploadMetadata? = nil) async throws -> TelegramUploadFile {
        guard mode == .video || video == nil else { throw TelegramUploadFileError.unavailable }
        let provisional = TelegramUploadFile(id: id, name: name, size: size, mode: mode, pixelWidth: video?.width, pixelHeight: video?.height,
            url: url, directory: directory, video: video, metadata: metadata)
        try validateOwnedStage(provisional)
        try await verifyMetadata(provisional)
        if mode == .file { return provisional }
        if mode == .video {
            guard let video, video.isValid(name: name, size: size) else { throw TelegramUploadFileError.invalidVideo }
            let info = try await TelegramUploadVideoIO.inspect(provisional)
            guard info.width == video.width, info.height == video.height,
                  info.duration == video.duration, info.hasAudio == video.hasAudio else { throw TelegramUploadFileError.invalidVideo }
            try Task.checkCancellation()
            return TelegramUploadFile(id: id, name: name, size: size, mode: mode,
                pixelWidth: video.width, pixelHeight: video.height, url: url, directory: directory, video: video, metadata: metadata)
        }
        _ = try await TelegramDownloadedFileIO.image(source: url, expectedSize: size)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int32Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int32Value,
              width > 0, height > 0, width <= photoMaximumPixelSize, height <= photoMaximumPixelSize else { throw TelegramUploadFileError.invalidImage }
        return TelegramUploadFile(id: id, name: name, size: size, mode: mode, pixelWidth: width, pixelHeight: height, url: url, directory: directory)
    }

    static func validateMetadata(_ file: TelegramUploadFile) throws {
        guard let metadata = file.metadata else { return }
        let invalid: TelegramUploadFileError
        switch metadata {
        case .audio: invalid = .invalidAudio
        case .webP: invalid = .invalidWebP
        case let .roundVideo(round):
            guard file.mode == .video, file.videoCover == nil,
                round.isValid(video: file.video, name: file.name, size: file.size),
                file.pixelWidth == file.video?.width, file.pixelHeight == file.video?.height else { throw TelegramUploadFileError.invalidVideo }
            return
        case .voice:
            invalid = .invalidVoice
            guard file.size > 0, file.size <= 20 * 1024 * 1024 else { throw invalid }
        case let .gif(gif):
            guard gif.isValid, file.videoCover == nil else { throw TelegramUploadFileError.invalidGIF }
            if file.mode == .file {
                guard file.video == nil, file.pixelWidth == nil, file.pixelHeight == nil,
                      file.size > 0, file.size <= 20 * 1024 * 1024 else { throw TelegramUploadFileError.invalidGIF }
            } else {
                guard file.mode == .video, let video = file.video, !video.hasAudio,
                      video.isValid(name: file.name, size: file.size),
                      (file.name as NSString).pathExtension == "mp4", file.size <= 128 * 1024 * 1024,
                      video.width == gif.width, video.height == gif.height,
                      file.pixelWidth == video.width, file.pixelHeight == video.height else { throw TelegramUploadFileError.invalidGIF }
            }
            return
        }
        guard file.mode == .file, file.video == nil, file.videoCover == nil,
              file.pixelWidth == nil, file.pixelHeight == nil, metadata.isValid else { throw invalid }
    }

    static func verifyMetadata(_ file: TelegramUploadFile) async throws {
        try Task.checkCancellation()
        try validateMetadata(file)
        guard let metadata = file.metadata else { return }
        switch metadata {
        case let .audio(frozen):
            guard try await TelegramUploadAudioIO.inspect(file) == frozen else { throw TelegramUploadFileError.invalidAudio }
        case let .webP(frozen):
            guard try await TelegramUploadWebPIO.inspect(file) == frozen else { throw TelegramUploadFileError.invalidWebP }
        case let .roundVideo(frozen):
            let facts = try await TelegramRecordedRoundVideoIO.inspect(file)
            guard facts.plaintextSHA256 == frozen.plaintextSHA256, facts.nativeDuration == frozen.nativeDuration else { throw TelegramUploadFileError.invalidVideo }
        case let .voice(frozen):
            let facts = try await TelegramRecordedVoiceIO.inspect(file)
            guard facts.sampleCount == frozen.sampleCount, facts.plaintextSHA256 == frozen.plaintextSHA256 else {
                throw TelegramUploadFileError.invalidVoice
            }
        case let .gif(frozen):
            if file.mode == .file {
                guard try await TelegramUploadGIFIO.inspect(file, expectedPlaintextSHA256: frozen.sourceSHA256) == frozen.info else {
                    throw TelegramUploadFileError.invalidGIF
                }
            } else {
                let info = try await TelegramUploadVideoIO.inspect(file)
                guard let video = file.video, info.width == frozen.width, info.height == frozen.height,
                      info.duration == video.duration, !info.hasAudio else { throw TelegramUploadFileError.invalidGIF }
            }
        }
        try Task.checkCancellation()
    }

    static func discard(_ file: TelegramUploadFile) throws {
        let exists = try discardableDirectory(file)
        if let cover = file.videoCover {
            guard file.mode == .video, file.id != cover.id else { throw TelegramUploadFileError.stagingFailed }
            _ = try discardableDirectory(cover.imageFile)
            try discard(cover.imageFile)
        }
        if exists {
            do { try FileManager.default.removeItem(at: file.directory) }
            catch { throw TelegramUploadFileError.stagingFailed }
        }
    }

    private static func discardableDirectory(_ file: TelegramUploadFile) throws -> Bool {
        let expected = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + file.id.uuidString, isDirectory: true)
        guard file.directory.standardizedFileURL == expected.standardizedFileURL,
              file.url.standardizedFileURL == expected.appendingPathComponent("payload-" + file.id.uuidString).standardizedFileURL else {
            throw TelegramUploadFileError.stagingFailed
        }
        var info = stat()
        if lstat(file.directory.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw TelegramUploadFileError.stagingFailed
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw TelegramUploadFileError.stagingFailed }
        return true
    }

    private static func prepare(_ source: URL, mode: TelegramUploadMode, coverCrop: CGRect?, expectedCoverSHA256: String?,
                                sourceByteLimit: Int64?, coverTransform: TelegramUploadVideoCoverTransform,
                                coverPainting: TelegramUploadVideoCoverPainting, coverImages: TelegramUploadVideoCoverImages,
                                photoSize: TelegramUploadPhotoSize) throws -> TelegramUploadFile {
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
        let modeCap: Int64 = mode == .photo ? 20 * 1024 * 1024 : 4 * 1024 * 1024 * 1024
        let cap = min(sourceByteLimit ?? modeCap, modeCap)
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
        if mode != .photo {
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
            if let expectedCoverSHA256,
               SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() != expectedCoverSHA256 {
                throw TelegramUploadFileError.unavailable
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
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: coverCrop == nil ? photoSize.maximumPixelSize : 8192,
                kCGImageSourceShouldCacheImmediately: true]
            guard var image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                throw TelegramUploadFileError.invalidImage
            }
            if let coverCrop {
                image = try coverTransform.render(image, crop: coverCrop, painting: coverPainting, images: coverImages)
            }
            let encoded = NSMutableData()
            if coverCrop == nil, let primary = TelegramUploadJPEGEncoder.encode(image) {
                encoded.append(primary)
            } else {
                guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else {
                    throw TelegramUploadFileError.stagingFailed
                }
                // Only decoded pixels and explicit quality; covers retain their existing encoder.
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: coverCrop == nil ? 0.75 : 1.0] as CFDictionary)
                guard CGImageDestinationFinalize(destination), encoded.length > 0 else { throw TelegramUploadFileError.invalidImage }
            }
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
