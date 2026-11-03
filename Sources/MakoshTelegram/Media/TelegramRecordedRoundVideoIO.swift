import Foundation
import AVFoundation
import AudioToolbox
import CoreVideo
import CryptoKit
import Darwin

/// Explicit recorded-video admission, never a classification of picker media.
public enum TelegramRecordedRoundVideoIO {
    private static let maximumBytes = 128 * 1024 * 1024

    public static func prepare(bytes: Data, isOneTime: Bool = false) async throws -> TelegramUploadFile {
        try Task.checkCancellation()
        guard !bytes.isEmpty else { throw TelegramUploadFileError.invalidVideo }
        guard bytes.count <= maximumBytes else { throw TelegramUploadFileError.tooLarge }
        let worker = Task.detached(priority: .utility) {
            let expectedDigest = try digest(bytes)
            let staged = try stage(bytes)
            do {
                let facts = try await probe(staged)
                try Task.checkCancellation()
                guard facts.plaintextSHA256 == expectedDigest else { throw TelegramUploadFileError.unavailable }
                let video = TelegramUploadVideoMetadata(width: facts.side, height: facts.side,
                    duration: facts.duration, hasAudio: true, inCollage: false)
                let metadata = TelegramUploadRoundVideoMetadata(nativeDuration: facts.nativeDuration,
                    plaintextSHA256: facts.plaintextSHA256, isOneTime: isOneTime)
                return TelegramUploadFile(id: staged.id, name: staged.name, size: staged.size, mode: .video,
                    pixelWidth: facts.side, pixelHeight: facts.side, url: staged.url, directory: staged.directory,
                    video: video, metadata: .roundVideo(metadata))
            } catch { try? TelegramUploadFileIO.discard(staged); throw error }
        }
        let file = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        do { try Task.checkCancellation(); return file }
        catch { try? TelegramUploadFileIO.discard(file); throw error }
    }

    struct Facts: Equatable, Sendable {
        let nativeDuration: Int32
        let plaintextSHA256: String
    }

    /// Restore re-derives codec, sample, container and byte facts; the intent flag is never byte inference.
    static func inspect(_ file: TelegramUploadFile) async throws -> Facts {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            guard file.mode == .video, file.name == "RoundVideo.mp4", file.videoCover == nil,
                  let video = file.video, let round = file.metadata?.roundVideo,
                  video.hasAudio, !video.inCollage,
                  file.pixelWidth == video.width, file.pixelHeight == video.height else {
                throw TelegramUploadFileError.invalidVideo
            }
            let actual = try await probe(file)
            guard video.width == actual.side, video.height == actual.side,
                  video.duration == actual.duration, round.nativeDuration == actual.nativeDuration,
                  round.plaintextSHA256 == actual.plaintextSHA256 else { throw TelegramUploadFileError.invalidVideo }
            return Facts(nativeDuration: actual.nativeDuration, plaintextSHA256: actual.plaintextSHA256)
        }
        let facts = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return facts
    }

    private struct Probe: Sendable {
        let side: Int32
        let duration: Double
        let nativeDuration: Int32
        let plaintextSHA256: String
    }

    private static func stage(_ bytes: Data) throws -> TelegramUploadFile {
        try Task.checkCancellation()
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + id.uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw TelegramUploadFileError.stagingFailed }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        guard chmod(directory.path, 0o700) == 0 else { throw TelegramUploadFileError.stagingFailed }
        let url = directory.appendingPathComponent("payload-" + id.uuidString)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TelegramUploadFileError.stagingFailed }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw TelegramUploadFileError.stagingFailed }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), min(65_536, buffer.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TelegramUploadFileError.stagingFailed }
                offset += count
            }
        }
        try Task.checkCancellation()
        let file = TelegramUploadFile(id: id, name: "RoundVideo.mp4", size: Int64(bytes.count), mode: .video,
            pixelWidth: nil, pixelHeight: nil, url: url, directory: directory)
        try TelegramUploadFileIO.validateOwnedStage(file)
        success = true
        return file
    }

    private static func probe(_ file: TelegramUploadFile) async throws -> Probe {
        try Task.checkCancellation()
        try TelegramUploadFileIO.validateOwnedStage(file)
        guard file.size > 0, file.size <= maximumBytes else { throw TelegramUploadFileError.invalidVideo }
        let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == getuid(), original.st_mode & 0o777 == 0o600,
              original.st_nlink == 1, original.st_size == file.size else { throw TelegramUploadFileError.unavailable }
        try validateContainer(fd, size: file.size)
        // AVFoundation reads the held inode, rather than reopening a replaceable path.
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/dev/fd/\(fd)"), options: [
            AVURLAssetOverrideMIMETypeKey: "video/mp4",
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue),
            AVURLAssetShouldSupportAliasDataReferencesKey: false
        ])
        defer { asset.cancelLoading() }
        do {
            return try await withTaskCancellationHandler {
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                // Own pre-encoded admission uses raw full-asset duration. Capture audio-end timing is a separate contract.
                guard playable, duration.isFinite, duration >= 0.5, duration <= 60 else { throw TelegramUploadFileError.invalidVideo }
                let tracks = try await asset.load(.tracks)
                let videos = tracks.filter { $0.mediaType == .video }, audios = tracks.filter { $0.mediaType == .audio }
                guard tracks.count == 2, videos.count == 1, audios.count == 1 else { throw TelegramUploadFileError.invalidVideo }
                let video = videos[0], audio = audios[0]
                let videoFormats = try await video.load(.formatDescriptions)
                guard !videoFormats.isEmpty else { throw TelegramUploadFileError.invalidVideo }
                let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormats[0])
                guard dimensions.width > 0, dimensions.width <= 1024, dimensions.width == dimensions.height,
                      videoFormats.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 &&
                          CMVideoFormatDescriptionGetDimensions($0).width == dimensions.width &&
                          CMVideoFormatDescriptionGetDimensions($0).height == dimensions.height }) else { throw TelegramUploadFileError.invalidVideo }
                let natural = try await video.load(.naturalSize), transform = try await video.load(.preferredTransform)
                let transformed = natural.applying(transform)
                guard natural.width == Double(dimensions.width), natural.height == Double(dimensions.height),
                      transformed.width.isFinite, transformed.height.isFinite,
                      abs(transformed.width) == Double(dimensions.width), abs(transformed.height) == Double(dimensions.height) else {
                    throw TelegramUploadFileError.invalidVideo
                }
                let audioFormats = try await audio.load(.formatDescriptions)
                guard !audioFormats.isEmpty, audioFormats.allSatisfy({ format in
                    guard CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC,
                          let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return false }
                    return stream.mSampleRate == 44_100 && stream.mChannelsPerFrame == 1
                }) else { throw TelegramUploadFileError.invalidVideo }
                let decoder = TelegramRoundVideoDecoder(asset: asset, video: video, audio: audio, side: dimensions.width)
                try await withTaskCancellationHandler { try await decoder.read() } onCancel: { Task { await decoder.cancel() } }
                try Task.checkCancellation()
                let hash = try digest(fd, size: file.size)
                try TelegramUploadVideoIO.validateSnapshot(file, fd: fd, original: original)
                return Probe(side: dimensions.width, duration: Double(Float32(duration)),
                    nativeDuration: Int32(ceil(duration)), plaintextSHA256: hash)
            } onCancel: { asset.cancelLoading() }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            try TelegramUploadVideoIO.validateSnapshot(file, fd: fd, original: original)
            if let error = error as? TelegramUploadFileError { throw error }
            throw TelegramUploadFileError.invalidVideo
        }
    }

    /// Finite top-level ISO-BMFF extents, MP4 brand, and media/movie atoms. No ignored trailing/truncated bytes.
    private static func validateContainer(_ fd: Int32, size: Int64) throws {
        var offset: Int64 = 0, count = 0, movie = 0, media = 0, type = 0
        while offset < size {
            try Task.checkCancellation()
            guard count < 4096, size - offset >= 8 else { throw TelegramUploadFileError.invalidVideo }
            let header = try read(fd, offset: offset, count: 8)
            var length = Int64(number(header.prefix(4))), headerSize: Int64 = 8
            let name = String(bytes: header.suffix(4), encoding: .ascii)
            if length == 1 {
                guard size - offset >= 16 else { throw TelegramUploadFileError.invalidVideo }
                let extended = number(try read(fd, offset: offset + 8, count: 8))
                guard extended <= UInt64(Int64.max) else { throw TelegramUploadFileError.invalidVideo }
                length = Int64(extended); headerSize = 16
            }
            guard length >= headerSize, length <= size - offset else { throw TelegramUploadFileError.invalidVideo }
            if name == "ftyp" {
                guard offset == 0, type == 0, headerSize == 8, length >= 16, length <= 1024, (length - 16) % 4 == 0 else {
                    throw TelegramUploadFileError.invalidVideo
                }
                let payload = try read(fd, offset: offset + 8, count: Int(length - 8))
                let brands = stride(from: 0, to: payload.count, by: 4).filter { $0 != 4 }.compactMap {
                    String(bytes: payload[$0..<($0 + 4)], encoding: .ascii)
                }
                guard !brands.contains("qt  "), brands.contains(where: { ["isom", "iso2", "iso6", "mp41", "mp42", "avc1", "M4V "].contains($0) }) else {
                    throw TelegramUploadFileError.invalidVideo
                }
                type += 1
            } else if name == "moov" { movie += 1 }
            else if name == "mdat" { media += 1 }
            offset += length; count += 1
        }
        guard type == 1, movie == 1, media > 0 else { throw TelegramUploadFileError.invalidVideo }
    }

    private static func number<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private static func read(_ fd: Int32, offset: Int64, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count), position = 0
        while position < count {
            try Task.checkCancellation()
            let result = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: position), count - position, off_t(offset + Int64(position))) }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw TelegramUploadFileError.unavailable }
            position += result
        }
        return bytes
    }
    private static func digest(_ fd: Int32, size: Int64) throws -> String {
        var hash = SHA256(), offset: Int64 = 0
        while offset < size {
            let bytes = try read(fd, offset: offset, count: Int(min(65_536, size - offset)))
            hash.update(data: Data(bytes)); offset += Int64(bytes.count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func digest(_ bytes: Data) throws -> String {
        var hash = SHA256(), offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let end = min(offset + 65_536, bytes.count)
            hash.update(data: bytes[(bytes.startIndex + offset)..<(bytes.startIndex + end)])
            offset = end
        }
        try Task.checkCancellation()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Apple forbids cancelReading concurrent with copyNextSampleBuffer. One actor owns both operations;
/// cancellation is checked and the actor yields between sample pulls, never interrupting a native pull.
private actor TelegramRoundVideoDecoder {
    private let asset: AVURLAsset
    private let video: AVAssetTrack
    private let audio: AVAssetTrack
    private let side: Int32
    private var reader: AVAssetReader?
    private var stopped = false
    init(asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack, side: Int32) {
        self.asset = asset; self.video = video; self.audio = audio; self.side = side
    }
    func read() async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let reader = try AVAssetReader(asset: asset)
        self.reader = reader
        defer { reader.cancelReading(); self.reader = nil }
        let pixels = AVAssetReaderTrackOutput(track: video,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let sound = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        pixels.alwaysCopiesSampleData = false; sound.alwaysCopiesSampleData = false
        guard reader.canAdd(pixels), reader.canAdd(sound) else { throw TelegramUploadFileError.invalidVideo }
        reader.add(pixels); reader.add(sound)
        guard reader.startReading() else { throw TelegramUploadFileError.invalidVideo }
        var videoDone = false, audioDone = false, frames = 0, samples = 0
        while !videoDone || !audioDone {
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            if !videoDone {
                if let sample = pixels.copyNextSampleBuffer() {
                    guard let buffer = CMSampleBufferGetImageBuffer(sample), CMSampleBufferDataIsReady(sample),
                          CVPixelBufferGetWidth(buffer) == side, CVPixelBufferGetHeight(buffer) == side else { throw TelegramUploadFileError.invalidVideo }
                    frames += 1
                    guard frames <= 7200 else { throw TelegramUploadFileError.invalidVideo }
                } else { videoDone = true }
            }
            try Task.checkCancellation()
            if !audioDone {
                if let sample = sound.copyNextSampleBuffer() {
                    let count = CMSampleBufferGetNumSamples(sample)
                    guard count > 0, CMSampleBufferDataIsReady(sample), count <= 2_647_024 - samples else { throw TelegramUploadFileError.invalidVideo }
                    samples += count
                } else { audioDone = true }
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        guard !stopped, reader.status == .completed, frames > 0, samples > 0 else { throw TelegramUploadFileError.invalidVideo }
    }
    func cancel() { stopped = true; reader?.cancelReading() }
}
