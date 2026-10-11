import Foundation
import AVFoundation
import Darwin
import UniformTypeIdentifiers

struct TelegramUploadVideoInfo: Equatable, Sendable {
    let width: Int32
    let height: Int32
    let duration: Double
    let hasAudio: Bool
    // Final Animated also depends on the preparation's collage choice.
    let animationEligible: Bool
}

enum TelegramUploadVideoIO {
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
        let asset = AVURLAsset(url: file.url, options: [
            AVURLAssetOverrideMIMETypeKey: mime,
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetShouldSupportAliasDataReferencesKey: false
        ])
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
}
