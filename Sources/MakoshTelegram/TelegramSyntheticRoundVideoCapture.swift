#if DEBUG
import AVFoundation
import Foundation
import CoreVideo
import AudioToolbox

/// Explicit synthetic-preview adapter; never creates an input or requests access.
@MainActor final class TelegramSyntheticRoundVideoCapture: TelegramRoundVideoCapture {
    private let capture: TelegramCameraRoundVideoCapture
    init() throws {
        capture = TelegramCameraRoundVideoCapture(authorization: { (.authorized, .authorized) },
            makeSource: { SyntheticRoundSampleSource() })
    }
    func start() async throws { try await capture.start() }
    func stop() async throws -> Data { try await capture.stop() }
    func cancel() { capture.cancel() }
    var duration: Double { capture.duration }
    var level: Float { capture.level }
    var isRecording: Bool { capture.isRecording }
    var previewSession: AVCaptureSession? { nil }
}

/// Own generated QA pixels/PCM enter the same writer as hardware samples.
@MainActor private final class SyntheticRoundSampleSource: TelegramRoundVideoCaptureSource {
    var previewSession: AVCaptureSession? { nil }
    private var operation: Task<Void, Never>?
    private var used = false
    isolated deinit { operation?.cancel() }
    func start(writer: TelegramRoundVideoCaptureWriter) async throws {
        guard !used else { throw TelegramRoundVideoCaptureError.invalidState }
        used = true
        // Buffer duration is real elapsed time, including the first buffer.
        try await Task.sleep(for: .milliseconds(200))
        try await append(frame: 0, to: writer)
        operation = Task {
            do {
                for frame in 1..<300 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard writer.snapshot.isRecording else { return }
                    try await append(frame: frame, to: writer)
                }
            } catch {
                if !Task.isCancelled { writer.cancel() }
            }
        }
    }
    func stop() async {
        let old = operation; operation = nil; old?.cancel(); await old?.value
    }
    func cancel() { operation?.cancel(); operation = nil }
    private func append(frame: Int, to writer: TelegramRoundVideoCaptureWriter) async throws {
        try Task.checkCancellation()
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 400, 300, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess,
              let pixels else { throw TelegramRoundVideoCaptureError.unavailable }
        CVPixelBufferLockBaseAddress(pixels, [])
        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
            CVPixelBufferUnlockBaseAddress(pixels, []); throw TelegramRoundVideoCaptureError.unavailable
        }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let data = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<300 { for x in 0..<400 {
            let offset = y * stride + x * 4
            data[offset] = UInt8(60 + x / 3)
            data[offset + 1] = UInt8(40 + y / 2)
            data[offset + 2] = UInt8(80 + frame % 100)
            data[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        try await writer.appendVideo(pixels, at: CMTime(value: Int64(frame), timescale: 5))
        try await writer.appendAudio(audio(frame: frame))
    }
    private func audio(frame: Int) throws -> CMSampleBuffer {
        let count = 8_820
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let samples = pcm.int16ChannelData?.pointee else { throw TelegramRoundVideoCaptureError.unavailable }
        pcm.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            samples[index] = Int16(sin(Double(frame * count + index) * 2 * .pi * 440 / 44_100) * 1_000)
        }
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, let description else { throw TelegramRoundVideoCaptureError.unavailable }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == noErr,
            let block, CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: count * 2) == noErr else { throw TelegramRoundVideoCaptureError.unavailable }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
            presentationTimeStamp: CMTime(value: Int64(frame * count), timescale: 44_100), decodeTimeStamp: .invalid)
        var size = 2, sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { throw TelegramRoundVideoCaptureError.unavailable }
        return sample
    }
}
#endif
