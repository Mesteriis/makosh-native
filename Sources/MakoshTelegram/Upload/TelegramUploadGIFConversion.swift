import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import Darwin

/// Independent native conversion. The caller holds and validates the source fd;
/// this worker receives only bounded, immutable, digest-checked GIF bytes.
enum TelegramUploadGIFConversion {
    static func write(_ data: Data, info: TelegramUploadGIFInfo, name: String) async throws -> TelegramUploadFile {
        try Task.checkCancellation()
        guard info.width > 0, info.height > 0, info.width <= 4096, info.height <= 4096,
              Int64(info.width) * Int64(info.height) <= 16_000_000,
              !info.frameDurations.isEmpty, info.frameDurations.count <= 256,
              Int64(info.width) * Int64(info.height) * Int64(info.frameDurations.count) <= 256_000_000,
              info.frameDurations.allSatisfy({ $0.isFinite && $0 > 0 }),
              info.frameDurations.reduce(0.0, { $0 + Double($1) }) <= 600 else {
            throw TelegramUploadGIFError.invalidGIF
        }
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("makosh-upload-" + id.uuidString, isDirectory: true)
        guard Darwin.mkdir(directory.path, 0o700) == 0 else { throw TelegramUploadFileError.stagingFailed }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        guard Darwin.chmod(directory.path, 0o700) == 0 else { throw TelegramUploadFileError.stagingFailed }
        let partial = directory.appendingPathComponent("partial-" + id.uuidString + ".mp4")
        let url = directory.appendingPathComponent("payload-" + id.uuidString)
        do {
            let encoder = GIFEncoder(data: data, info: info, url: partial)
            do {
                try await withTaskCancellationHandler {
                    try await encoder.encode()
                    try Task.checkCancellation()
                } onCancel: {
                    // cancelWriting may block. Only schedule work here; the native
                    // call runs on the encoder actor, never the cancelling UI thread.
                    Task.detached { await encoder.cancel() }
                }
            } catch {
                // Await native teardown before deleting its private output folder.
                await encoder.cancel()
                throw error
            }
            let size = try validateSize(partial, allowEmpty: false)
            let fd = Darwin.open(partial.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw TelegramUploadFileError.stagingFailed }
            defer { Darwin.close(fd) }
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0, Darwin.rename(partial.path, url.path) == 0 else {
                throw TelegramUploadFileError.stagingFailed
            }
            let file = TelegramUploadFile(id: id,
                name: telegramAttachmentName((name as NSString).deletingPathExtension + ".mp4"),
                size: size, mode: .video, pixelWidth: nil, pixelHeight: nil, url: url, directory: directory)
            let video = try await TelegramUploadVideoIO.inspect(file)
            guard video.width == info.width, video.height == info.height, !video.hasAudio else {
                throw TelegramUploadGIFError.invalidGIF
            }
            try await validateCodec(file)
            try Task.checkCancellation()
            try TelegramUploadFileIO.validateOwnedStage(file)
            let output = TelegramUploadFile(id: id, name: file.name, size: size, mode: .video,
                pixelWidth: video.width, pixelHeight: video.height, url: url, directory: directory,
                video: .init(width: video.width, height: video.height, duration: video.duration,
                    hasAudio: false, inCollage: true))
            success = true
            return output
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let known = error as? TelegramUploadFileError,
               known == .unavailable || known == .stagingFailed { throw known }
            throw TelegramUploadGIFError.invalidGIF
        }
    }

    fileprivate static func validateSize(_ url: URL, allowEmpty: Bool) throws -> Int64 {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_mode & 0o777 == 0o600,
              status.st_size >= (allowEmpty ? 0 : 1), status.st_size <= 128 * 1024 * 1024 else {
            throw TelegramUploadGIFError.invalidGIF
        }
        return status.st_size
    }

    private static func validateCodec(_ file: TelegramUploadFile) async throws {
        let asset = AVURLAsset(url: file.url, options: [
            AVURLAssetOverrideMIMETypeKey: "video/mp4",
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetShouldSupportAliasDataReferencesKey: false
        ])
        defer { asset.cancelLoading() }
        try await withTaskCancellationHandler {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard tracks.count == 1, let track = tracks.first else { throw TelegramUploadGIFError.invalidGIF }
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty,
                  descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else {
                throw TelegramUploadGIFError.invalidGIF
            }
            try Task.checkCancellation()
        } onCancel: { asset.cancelLoading() }
    }
}

/// All mutable writer/input/adaptor calls stay on this actor. Native completion
/// only schedules an actor message; the continuation is consumed exactly once.
private actor GIFEncoder {
    private let data: Data
    private let info: TelegramUploadGIFInfo
    private let url: URL
    private var writer: AVAssetWriter?
    private var stopped = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(data: Data, info: TelegramUploadGIFInfo, url: URL) {
        self.data = data
        self.info = info
        self.url = url
    }

    func encode() async throws {
        try checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == info.frameDurations.count else {
            throw TelegramUploadGIFError.invalidGIF
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        self.writer = writer
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(info.width), AVVideoHeightKey: Int(info.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 512_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264High40,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw TelegramUploadGIFError.invalidGIF
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw TelegramUploadGIFError.invalidGIF }
        writer.add(input)
        // This API is available on macOS26; its SDK27 replacement requires27.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(info.width),
                kCVPixelBufferHeightKey as String: Int(info.height),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
        guard writer.startWriting() else { throw TelegramUploadGIFError.invalidGIF }
        writer.startSession(atSourceTime: .zero)
        guard Darwin.chmod(url.path, 0o600) == 0 else { throw TelegramUploadFileError.stagingFailed }
        guard let pool = adaptor.pixelBufferPool else { throw TelegramUploadGIFError.invalidGIF }
        var elapsed: Double = 0
        let count = info.frameDurations.count
        let repeatLast = Double(info.frameDurations[count - 1]) > 0.33
        for sample in 0..<(count + (repeatLast ? 1 : 0)) {
            try checkCancellation()
            guard writer.status == .writing else { throw TelegramUploadGIFError.invalidGIF }
            while !input.isReadyForMoreMediaData {
                try checkCancellation()
                guard writer.status == .writing else { throw TelegramUploadGIFError.invalidGIF }
                try await Task.sleep(for: .milliseconds(5))
            }
            try checkCancellation()
            let index = min(sample, count - 1)
            let pixels = try Self.decode(source, index: index, info: info, pool: pool)
            try checkCancellation()
            guard adaptor.append(pixels, withPresentationTime: CMTime(seconds: elapsed, preferredTimescale: 600)) else {
                throw TelegramUploadGIFError.invalidGIF
            }
            elapsed += Double(info.frameDurations[index])
            _ = try TelegramUploadGIFConversion.validateSize(url, allowEmpty: true)
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishContinuation = continuation
            writer.finishWriting { [weak self] in
                Task { await self?.finishCompleted() }
            }
        }
        try checkCancellation()
        guard writer.status == .completed else { throw TelegramUploadGIFError.invalidGIF }
    }

    func cancel() {
        guard !stopped else { return }
        stopped = true
        if let writer, writer.status == .writing { writer.cancelWriting() }
        finishCompleted()
    }

    private func finishCompleted() {
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume()
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
    }

    /// Synchronous native work has no actor hop or shared escaping closure. Only
    /// the writer actor calls it, between its cancellation/readiness awaits.
    private nonisolated static func decode(_ source: CGImageSource, index: Int,
                                          info: TelegramUploadGIFInfo, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        try autoreleasepool {
            guard let image = CGImageSourceCreateImageAtIndex(source, index,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  image.width == Int(info.width), image.height == Int(info.height),
                  CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
                throw TelegramUploadGIFError.invalidGIF
            }
            return try buffer(image, pool: pool)
        }
    }

    private nonisolated static func buffer(_ image: CGImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &result) == kCVReturnSuccess,
              let pixels = result,
              CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess else {
            throw TelegramUploadGIFError.invalidGIF
        }
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard CVPixelBufferGetWidth(pixels) == image.width, CVPixelBufferGetHeight(pixels) == image.height,
              CVPixelBufferGetBytesPerRow(pixels) >= image.width * 4,
              let bytes = CVPixelBufferGetBaseAddress(pixels),
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: bytes, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: color,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw TelegramUploadGIFError.invalidGIF
        }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return pixels
    }
}
