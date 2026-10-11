import Foundation
import AVFoundation
import Darwin
import UniformTypeIdentifiers
import ImageIO

struct TelegramUploadVideoThumbnail: Sendable {
    let data: Data
    let width: Int32
    let height: Int32
}

struct TelegramUploadVideoInfo: Equatable, Sendable {
    let width: Int32
    let height: Int32
    let duration: Double
    let hasAudio: Bool
    // Final Animated also depends on the preparation's collage choice.
    let animationEligible: Bool
}

enum TelegramUploadVideoIO {
    static func thumbnail(_ file: TelegramUploadFile) async throws -> TelegramUploadVideoThumbnail {
        let preview = try await poster(file)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TelegramUploadFileError.invalidVideo
        }
        CGImageDestinationAddImage(destination, preview.image,
            [kCGImageDestinationLossyCompressionQuality: 0.3] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0, data.length <= 1_048_576 else {
            throw TelegramUploadFileError.invalidVideo
        }
        try Task.checkCancellation()
        return TelegramUploadVideoThumbnail(data: data as Data,
            width: Int32(preview.image.width), height: Int32(preview.image.height))
    }

    /// Reference SenderController.previewForFile: first frame, transformed,320px.
    static func poster(_ file: TelegramUploadFile) async throws -> TelegramImagePreview {
        try Task.checkCancellation()
        try TelegramUploadFileIO.validateOwnedStage(file)
        guard file.mode == .video, let video = file.video,
              video.isValid(name: file.name, size: file.size),
              file.pixelWidth == video.width, file.pixelHeight == video.height else {
            throw TelegramUploadFileError.invalidVideo
        }
        let info = try await inspect(file)
        guard info.width == video.width, info.height == video.height,
              info.duration == video.duration, info.hasAudio == video.hasAudio else {
            throw TelegramUploadFileError.invalidVideo
        }
        let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_size == file.size else { throw TelegramUploadFileError.unavailable }
        let asset = try restrictedAsset(file)
        let decoder = TelegramUploadVideoPosterDecoder(asset: asset)
        do {
            let preview = try await withTaskCancellationHandler {
                try await decoder.frame()
            } onCancel: { Task { await decoder.cancel() } }
            try Task.checkCancellation()
            try validateSnapshot(file, fd: fd, original: original)
            guard preview.image.width > 0, preview.image.height > 0,
                  preview.image.width <= 320, preview.image.height <= 320 else {
                throw TelegramUploadFileError.invalidVideo
            }
            return preview
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? TelegramUploadFileError { throw error }
            throw TelegramUploadFileError.invalidVideo
        }
    }

    /// Inspect the owned immutable copy, never the picker URL or nested media URLs.
    /// The reference preserves video bytes; this does not transcode or strip metadata.
    static func inspect(_ file: TelegramUploadFile) async throws -> TelegramUploadVideoInfo {
        try Task.checkCancellation()
        try TelegramUploadFileIO.validateOwnedStage(file)
        guard file.size > 0,
              let mime = UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType,
              mime.hasPrefix("video/") else { throw TelegramUploadFileError.invalidVideo }
        let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_size == file.size else { throw TelegramUploadFileError.unavailable }
        let asset = try restrictedAsset(file)
        defer { asset.cancelLoading() }
        do {
            return try await withTaskCancellationHandler {
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                try Task.checkCancellation()
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard playable, duration.isFinite, duration > 0, duration <= 7 * 24 * 60 * 60,
                      let track = tracks.first else { throw TelegramUploadFileError.invalidVideo }
                let natural = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let display = natural.applying(transform)
                let width = floor(abs(display.width)), height = floor(abs(display.height))
                guard width.isFinite, height.isFinite, width > 0, height > 0,
                      width <= 8192, height <= 8192, width * height <= 40_000_000 else {
                    throw TelegramUploadFileError.invalidVideo
                }
                let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
                try Task.checkCancellation()
                try validateSnapshot(file, fd: fd, original: original)
                let animated = !hasAudio && file.size < 10 * 1024 * 1024 &&
                    (file.name as NSString).pathExtension.lowercased() == "mp4"
                // TelegramMediaFileAttribute.Video decodes via Float32 in both
                // Postbox and FlatBuffers; freeze that value before persistence.
                return TelegramUploadVideoInfo(width: Int32(width), height: Int32(height),
                    duration: Double(Float32(duration)), hasAudio: hasAudio, animationEligible: animated)
            } onCancel: { asset.cancelLoading() }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? TelegramUploadFileError { throw error }
            throw TelegramUploadFileError.invalidVideo
        }
    }

    private static func restrictedAsset(_ file: TelegramUploadFile) throws -> AVURLAsset {
        guard let mime = UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType,
              mime.hasPrefix("video/") else { throw TelegramUploadFileError.invalidVideo }
        return AVURLAsset(url: file.url, options: [
            AVURLAssetOverrideMIMETypeKey: mime,
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetShouldSupportAliasDataReferencesKey: false
        ])
    }

    private static func validateSnapshot(_ file: TelegramUploadFile, fd: Int32, original: stat) throws {
        try TelegramUploadFileIO.validateOwnedStage(file)
        var final = stat(), currentPath = stat()
        guard fstat(fd, &final) == 0, lstat(file.url.path, &currentPath) == 0,
              currentPath.st_mode & S_IFMT == S_IFREG,
              currentPath.st_dev == original.st_dev, currentPath.st_ino == original.st_ino,
              final.st_size == original.st_size,
              final.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw TelegramUploadFileError.unavailable
        }
    }
}

/// Keep the mutable native generator on one actor. Only immutable image values
/// cross executors; cancellation before/during frame generation is remembered.
private actor TelegramUploadVideoPosterDecoder {
    private let asset: AVURLAsset
    private var generator: AVAssetImageGenerator?
    private var stopped = false
    init(asset: AVURLAsset) { self.asset = asset }

    func frame() async throws -> TelegramImagePreview {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        self.generator = generator
        defer { generator.cancelAllCGImageGeneration(); self.generator = nil; asset.cancelLoading() }
        let preview: TelegramImagePreview = try await withCheckedThrowingContinuation { continuation in
            // AVFoundation promises one callback for this one requested time,
            // including a cancelled generation; no guessed callback timeout.
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, result, _ in
                if result == .succeeded, let image {
                    continuation.resume(returning: TelegramImagePreview(image: image))
                } else {
                    continuation.resume(throwing: TelegramUploadFileError.invalidVideo)
                }
            }
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        return preview
    }

    func cancel() {
        stopped = true
        generator?.cancelAllCGImageGeneration()
        asset.cancelLoading()
    }
}
