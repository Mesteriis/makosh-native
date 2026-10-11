import Foundation
import AVFoundation
import AudioToolbox
import CoreVideo
import Darwin

/// All native writer operations, including capture delegates, use this one queue.
/// The async entry points transfer read ownership of a sample until they return.
final class TelegramRoundVideoCaptureWriter: @unchecked Sendable {
    struct Snapshot: Sendable {
        var duration: Double = 0
        var level: Float = 0
        var isRecording = false
        var lastAudioHostTime: Double = 0
    }
    private struct Pixels: @unchecked Sendable { let value: CVPixelBuffer; let time: CMTime }
    private struct Audio: @unchecked Sendable { let value: CMSampleBuffer }
    private struct Identity { let device: dev_t; let inode: ino_t }
    let directory: URL
    let sampleQueue = DispatchQueue(label: "Makosh.round-video.samples", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var published = Snapshot()
    private var cancelled = false
    private let directoryIdentity: Identity
    private let outputURL: URL
    private let native: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let isVideoReady: @Sendable (AVAssetWriterInput) -> Bool
    private var nativeStarted = false
    private var firstVideo: CMTime?
    private var lastVideo: CMTime?
    private var audioEnd: CMTime?
    private var videoCount = 0
    private var audioCount = 0
    private var finishing = false
    private var result: Data?
    private var failure: (any Error)?
    private var waiters: [CheckedContinuation<Data, any Error>] = []
    private var outputIdentity: Identity?

    init(isVideoReady: @escaping @Sendable (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData }) throws {
        var pattern = Array(FileManager.default.temporaryDirectory.appendingPathComponent("makosh-round-XXXXXX").path.utf8CString)
        guard mkdtemp(&pattern) != nil else { throw TelegramRoundVideoCaptureError.unavailable }
        let folder = URL(fileURLWithPath: String(decoding: pattern.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
        var info = stat()
        guard chmod(folder.path, 0o700) == 0, lstat(folder.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            try? FileManager.default.removeItem(at: folder)
            throw TelegramRoundVideoCaptureError.unavailable
        }
        do {
            let url = folder.appendingPathComponent("capture.mp4")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 300, AVVideoHeightKey: 300,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAllowFrameReorderingKey: false]
            ])
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
            ])
            guard writer.canAdd(v), writer.canAdd(a) else { throw TelegramRoundVideoCaptureError.unavailable }
            v.expectsMediaDataInRealTime = true; a.expectsMediaDataInRealTime = true
            writer.add(v); writer.add(a)
            let p = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 300, kCVPixelBufferHeightKey as String: 300,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
            directory = folder; outputURL = url; directoryIdentity = Identity(device: info.st_dev, inode: info.st_ino)
            native = writer; video = v; audio = a; adaptor = p; self.isVideoReady = isVideoReady
            sampleQueue.setSpecific(key: queueKey, value: true)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    var snapshot: Snapshot { lock.withLock { published } }
    private var isCancelled: Bool { lock.withLock { cancelled } }
    private func publish(recording: Bool? = nil, duration: Double? = nil, level: Float? = nil, audioTime: Double? = nil) {
        lock.withLock {
            if let recording { published.isRecording = recording && !cancelled }
            if let duration { published.duration = duration }
            if let level { published.level = level }
            if let audioTime { published.lastAudioHostTime = audioTime }
        }
    }

    @MainActor func appendVideo(_ pixels: CVPixelBuffer, at time: CMTime) async throws {
        let packet = Pixels(value: pixels, time: time)
        try await enqueue { try self.consumeVideo(packet.value, at: packet.time) }
    }
    @MainActor func appendAudio(_ sample: CMSampleBuffer) async throws {
        let packet = Audio(value: sample)
        try await enqueue { try self.consumeAudio(packet.value) }
    }
    private func enqueue(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                sampleQueue.async { self.attempt(operation, deadline: ProcessInfo.processInfo.systemUptime + 2, continuation: continuation) }
            }
        } onCancel: { self.cancel() }
    }
    private func attempt(_ operation: @escaping @Sendable () throws -> Void, deadline: Double,
                         continuation: CheckedContinuation<Void, any Error>) {
        do { try operation(); continuation.resume() }
        catch TelegramRoundVideoCaptureError.backpressure where ProcessInfo.processInfo.systemUptime < deadline {
            sampleQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { self.attempt(operation, deadline: deadline, continuation: continuation) }
        } catch { continuation.resume(throwing: error) }
    }

    // These two synchronous methods are called only on sampleQueue by native capture delegates.
    func consumeVideo(_ pixels: CVPixelBuffer, at time: CMTime) throws {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        try checkActive()
        guard time.isValid, time.isNumeric, time.seconds.isFinite, time.seconds >= 0,
              lastVideo.map({ CMTimeCompare(time, $0) > 0 }) ?? true,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixels), (1...4096).contains(CVPixelBufferGetWidth(pixels)),
              (1...4096).contains(CVPixelBufferGetHeight(pixels)), videoCount < 7200 else {
            throw terminate(TelegramRoundVideoCaptureError.invalidSample)
        }
        if let firstVideo, CMTimeSubtract(time, firstVideo).seconds >= 60 { beginFinish(); return }
        if !nativeStarted {
            guard native.startWriting() else { throw terminate(TelegramRoundVideoCaptureError.unavailable) }
            nativeStarted = true
        }
        try secureOutput()
        guard isVideoReady(video) else { throw TelegramRoundVideoCaptureError.backpressure }
        let output = try render(pixels)
        if firstVideo == nil { native.startSession(atSourceTime: time) }
        guard adaptor.append(output, withPresentationTime: time) else { throw terminate(TelegramRoundVideoCaptureError.invalidRecording) }
        if firstVideo == nil { firstVideo = time }
        lastVideo = time; videoCount += 1
        try secureOutput()
    }

    func consumeAudio(_ sample: CMSampleBuffer) throws {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        try checkActive()
        guard CMSampleBufferDataIsReady(sample), let format = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              stream.mFormatID == kAudioFormatLinearPCM, stream.mSampleRate == 44_100,
              stream.mChannelsPerFrame == 1, stream.mBitsPerChannel == 16,
              stream.mBytesPerFrame == 2, stream.mBytesPerPacket == 2, stream.mFramesPerPacket == 1,
              stream.mFormatFlags == kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
              let block = CMSampleBufferGetDataBuffer(sample) else { throw terminate(TelegramRoundVideoCaptureError.invalidSample) }
        let count = CMSampleBufferGetNumSamples(sample), time = CMSampleBufferGetPresentationTimeStamp(sample)
        let expectedDuration = CMTime(value: Int64(count), timescale: 44_100)
        let sampleDuration = CMSampleBufferGetDuration(sample)
        guard count > 0, count <= 44_100 * 2, CMBlockBufferGetDataLength(block) == count * 2,
              sampleDuration.isValid, sampleDuration.isNumeric, CMTimeCompare(sampleDuration, expectedDuration) == 0,
              time.isValid, time.isNumeric, time.seconds.isFinite, time.seconds >= 0,
              audioCount <= 2_647_024 - count,
              audioEnd.map({ CMTimeCompare(time, $0) >= 0 }) ?? true else {
            throw terminate(TelegramRoundVideoCaptureError.invalidSample)
        }
        guard let firstVideo else { return } // Warmup audio is not recording time.
        guard CMTimeCompare(time, firstVideo) >= 0 else { return }
        let end = CMTimeAdd(time, CMTime(value: Int64(count), timescale: 44_100))
        let duration = CMTimeSubtract(end, firstVideo).seconds
        guard duration <= 60 else { beginFinish(); return }
        guard audio.isReadyForMoreMediaData else { throw TelegramRoundVideoCaptureError.backpressure }
        guard audio.append(sample) else { throw terminate(TelegramRoundVideoCaptureError.invalidRecording) }
        audioEnd = end; audioCount += count
        // The native buffer stays immutable while it is used by the encoder.
        var amplitude: UInt64 = 0
        var samples = [Int16](repeating: 0, count: count)
        let copied = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: $0.baseAddress!) }
        if copied == noErr { for value in samples { amplitude += UInt64(abs(Int(value))) } }
        publish(recording: true, duration: duration, level: Float(amplitude) / Float(count) / 32768,
                audioTime: ProcessInfo.processInfo.systemUptime)
        try secureOutput()
        if duration >= 60 { beginFinish() }
    }

    private func checkActive() throws {
        if isCancelled { throw terminate(CancellationError()) }
        if let failure { throw failure }
        if finishing || result != nil { throw TelegramRoundVideoCaptureError.invalidState }
    }
    func waitUntilReady(timeout: Double = 10) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, min(timeout, 10))
        while true {
            try Task.checkCancellation()
            let ready: Bool = try await withCheckedThrowingContinuation { continuation in
                sampleQueue.async {
                    if self.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else if let failure = self.failure { continuation.resume(throwing: failure) }
                    else { continuation.resume(returning: self.firstVideo != nil && self.audioEnd != nil) }
                }
            }
            if ready { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw TelegramRoundVideoCaptureError.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func finish() async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                sampleQueue.async {
                    if self.isCancelled { continuation.resume(throwing: self.terminate(CancellationError())) }
                    else if let failure = self.failure { continuation.resume(throwing: failure) }
                    else if let result = self.result { continuation.resume(returning: result) }
                    else { self.waiters.append(continuation); self.beginFinish() }
                }
            }
        } onCancel: { self.cancel() }
    }
    private func beginFinish() {
        guard !finishing, result == nil, failure == nil else { return }
        guard !isCancelled else { _ = terminate(CancellationError()); return }
        guard let firstVideo, let audioEnd, CMTimeSubtract(audioEnd, firstVideo).seconds >= 0.5,
              CMTimeSubtract(audioEnd, firstVideo).seconds <= 60 else {
            _ = terminate(TelegramRoundVideoCaptureError.invalidRecording); return
        }
        do { try secureOutput() } catch { _ = terminate(error); return }
        finishing = true; publish(recording: false)
        native.endSession(atSourceTime: audioEnd)
        video.markAsFinished(); audio.markAsFinished()
        native.finishWriting { [self] in
            sampleQueue.async { [self] in
                if isCancelled { _ = terminate(CancellationError()); return }
                guard native.status == .completed else { _ = terminate(TelegramRoundVideoCaptureError.invalidRecording); return }
                do {
                    let bytes = try readOwnedOutput()
                    guard !isCancelled else { throw CancellationError() }
                    cleanup(); result = bytes
                    let pending = waiters; waiters.removeAll()
                    pending.forEach { $0.resume(returning: bytes) }
                } catch { _ = terminate(error) }
            }
        }
    }
    func cancel() {
        lock.withLock { cancelled = true; published.isRecording = false }
        sampleQueue.async { _ = self.terminate(CancellationError()) }
    }
    func fail() { sampleQueue.async { _ = self.terminate(TelegramRoundVideoCaptureError.unavailable) } }
    @discardableResult private func terminate(_ error: any Error) -> any Error {
        let terminal: any Error = isCancelled ? CancellationError() : (failure ?? error)
        failure = terminal; result = nil; publish(recording: false)
        if native.status == .writing || native.status == .unknown { native.cancelWriting() }
        cleanup()
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume(throwing: terminal) }
        return terminal
    }

    private func render(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { throw terminate(TelegramRoundVideoCaptureError.invalidRecording) }
        var target: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary, &target)
        if status == kCVReturnWouldExceedAllocationThreshold { throw TelegramRoundVideoCaptureError.backpressure }
        guard status == kCVReturnSuccess, let target else { throw terminate(TelegramRoundVideoCaptureError.invalidRecording) }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { throw terminate(TelegramRoundVideoCaptureError.invalidSample) }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(target, []) == kCVReturnSuccess else { throw terminate(TelegramRoundVideoCaptureError.invalidRecording) }
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source), side = min(width, height)
        let sourceStride = CVPixelBufferGetBytesPerRow(source), targetStride = CVPixelBufferGetBytesPerRow(target)
        guard sourceStride >= width * 4, targetStride >= 300 * 4,
              let src = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self),
              let dst = CVPixelBufferGetBaseAddress(target)?.assumingMemoryBound(to: UInt8.self) else {
            throw terminate(TelegramRoundVideoCaptureError.invalidSample)
        }
        for y in 0..<300 {
            if isCancelled { throw terminate(CancellationError()) }
            let sy = (height - side) / 2 + min(side - 1, y * side / 300)
            for x in 0..<300 {
                let sx = (width - side) / 2 + min(side - 1, (299 - x) * side / 300)
                let sourceOffset = sy * sourceStride + sx * 4, targetOffset = y * targetStride + x * 4
                let distance = hypot(Double(x) + 0.5 - 150, Double(y) + 0.5 - 150)
                let coverage = max(0, min(1, 150.5 - distance))
                for channel in 0..<3 { dst[targetOffset + channel] = UInt8((Double(src[sourceOffset + channel]) * coverage + 255 * (1 - coverage)).rounded()) }
                dst[targetOffset + 3] = 255
            }
        }
        return target
    }

    private func directoryIsOwned() -> Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o777 == 0o700 && info.st_dev == directoryIdentity.device && info.st_ino == directoryIdentity.inode
    }
    private func secureOutput() throws {
        guard directoryIsOwned() else { throw terminate(TelegramRoundVideoCaptureError.invalidRecording) }
        let fd = open(outputURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT, outputIdentity == nil { return }
        guard fd >= 0 else { throw terminate(TelegramRoundVideoCaptureError.invalidRecording) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= 128 * 1024 * 1024,
              outputIdentity.map({ $0.device == info.st_dev && $0.inode == info.st_ino }) ?? true,
              fchmod(fd, 0o600) == 0 else { throw terminate(TelegramRoundVideoCaptureError.invalidRecording) }
        outputIdentity = Identity(device: info.st_dev, inode: info.st_ino)
    }
    private func readOwnedOutput() throws -> Data {
        try secureOutput()
        let fd = open(outputURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramRoundVideoCaptureError.invalidRecording }
        defer { close(fd) }
        var before = stat()
        guard directoryIsOwned(), fstat(fd, &before) == 0, before.st_size > 0, before.st_size <= 128 * 1024 * 1024,
              before.st_mode & S_IFMT == S_IFREG, before.st_mode & 0o777 == 0o600, before.st_uid == getuid(), before.st_nlink == 1,
              let identity = outputIdentity, identity.device == before.st_dev, identity.inode == before.st_ino else {
            throw TelegramRoundVideoCaptureError.invalidRecording
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        bytes.reserveCapacity(Int(before.st_size))
        while bytes.count < before.st_size {
            if isCancelled { throw CancellationError() }
            let count = read(fd, &buffer, min(buffer.count, Int(before.st_size) - bytes.count))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw TelegramRoundVideoCaptureError.invalidRecording }
            bytes.append(buffer, count: count)
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, lstat(outputURL.path, &path) == 0, directoryIsOwned(),
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              path.st_dev == before.st_dev, path.st_ino == before.st_ino, path.st_mode & S_IFMT == S_IFREG else {
            throw TelegramRoundVideoCaptureError.invalidRecording
        }
        return bytes
    }
    private func cleanup() {
        // Never recursively remove a directory substituted for the one this writer created.
        if directoryIsOwned() { try? FileManager.default.removeItem(at: directory) }
    }
    deinit {
        let dispose = { if self.native.status == .writing || self.native.status == .unknown { self.native.cancelWriting() }; self.cleanup() }
        if DispatchQueue.getSpecific(key: queueKey) == true { dispose() } else { sampleQueue.sync(execute: dispose) }
    }
}
