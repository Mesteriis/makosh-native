import XCTest
import AVFoundation
import AudioToolbox
import CoreVideo
import Darwin
@testable import MakoshTelegram

@MainActor final class TelegramRoundVideoCaptureWriterTests: XCTestCase {
    // Catches encoding the wrong codec/audio format or replacing full-asset schema13 timing.
    func testRealSamplesProduceInspectableRoundBytesAndRemovePrivateStage() async throws {
        let writer = try TelegramRoundVideoCaptureWriter()
        defer { writer.cancel() }
        var info = stat()
        XCTAssertEqual(lstat(writer.directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        do {
            try await roundCaptureFeed(writer)
            try await writer.waitUntilReady()
            let bytes = try await writer.finish()
            let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
            defer { try? TelegramUploadFileIO.discard(file) }
            XCTAssertEqual(file.video?.width, 300); XCTAssertEqual(file.video?.height, 300)
            XCTAssertEqual(try XCTUnwrap(file.video).duration, 1, accuracy: 0.001)
            XCTAssertEqual(file.metadata?.roundVideo?.nativeDuration, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.directory.path))
            let retained = try await writer.finish(); XCTAssertEqual(retained, bytes)
        } catch { XCTFail("Native recording samples refused: \(error)") }
    }
    // Catches leaving uncropped side bars, omitting mirror, or clipping only the preview UI.
    func testEncodedPixelsHaveCenterCropMirrorAndOpaqueWhiteCircle() async throws {
        let writer = try TelegramRoundVideoCaptureWriter(); defer { writer.cancel() }
        do {
            try await roundCaptureFeed(writer)
            let bytes = try await writer.finish()
            let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
            defer { try? TelegramUploadFileIO.discard(file) }
            // A staged upload intentionally has no extension; the independent decoder gets
            // a typed local MP4 fixture containing the exact returned encoded bytes.
            let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
            let fixtureURL = fixtureDirectory.appendingPathComponent("encoded.mp4")
            try bytes.write(to: fixtureURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixtureURL.path)
            let asset = AVURLAsset(url: fixtureURL), tracks = try await asset.loadTracks(withMediaType: .video)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading()); defer { reader.cancelReading() }
            let sample = try XCTUnwrap(output.copyNextSampleBuffer()), pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(pixels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let data = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
            let corner = 5 * stride + 5 * 4, left = 150 * stride + 75 * 4, right = 150 * stride + 225 * 4
            XCTAssertGreaterThan(data[corner], 235); XCTAssertGreaterThan(data[corner+1], 235); XCTAssertGreaterThan(data[corner+2], 235)
            XCTAssertGreaterThan(data[left], 200); XCTAssertLessThan(data[left+2], 45)
            XCTAssertGreaterThan(data[right+2], 200); XCTAssertLessThan(data[right], 45)
        } catch { XCTFail("Encoded crop/mirror pixels unavailable: \(error)") }
    }
    // Catches trusting timestamps after duplicate/backwards frames or relabelling unsupported PCM.
    func testInvalidTimestampAndWrongAudioFormatAreTerminalAndCleanUp() async throws {
        for wrongAudio in [false,true] {
            let writer = try TelegramRoundVideoCaptureWriter()
            do {
                try await writer.appendVideo(roundCapturePixels(), at: .zero)
                if wrongAudio { try await writer.appendAudio(roundCaptureAudio(offset: 0, count: 1024, rate: 48_000)) }
                else { try await writer.appendVideo(roundCapturePixels(), at: .zero) }
                XCTFail("Malformed sample admitted")
            } catch { XCTAssertEqual(error as? TelegramRoundVideoCaptureError, .invalidSample) }
            writer.cancel()
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.directory.path))
        }
    }
    // Catches pre-video audio manufacturing readiness and a short file escaping the native lower bound.
    func testAudioBeforeVideoDoesNotStartAndShortRecordingIsRefused() async throws {
        let writer = try TelegramRoundVideoCaptureWriter(); defer { writer.cancel() }
        try? await writer.appendAudio(roundCaptureAudio(offset: 0, count: 4410))
        XCTAssertFalse(writer.snapshot.isRecording)
        do {
            try await roundCaptureFeed(writer, frames: 3)
            _ = try await writer.finish(); XCTFail("Short recording admitted")
        } catch { XCTAssertEqual(error as? TelegramRoundVideoCaptureError, .invalidRecording) }
    }
    // Catches a recording continuing past60s or losing bytes when native completion precedes user release.
    func testSampleClockCapRetainsCompletedBytesAndNeverExceedsSixtySeconds() async throws {
        let writer = try TelegramRoundVideoCaptureWriter(); defer { writer.cancel() }
        do {
            try await writer.appendVideo(roundCapturePixels(), at: .zero)
            for second in 0..<60 {
                if second > 0 { try await writer.appendVideo(roundCapturePixels(), at: CMTime(value: Int64(second), timescale: 1)) }
                try await writer.appendAudio(roundCaptureAudio(offset: second * 44_100, count: 44_100))
            }
            XCTAssertFalse(writer.snapshot.isRecording)
            let bytes = try await writer.finish(), retained = try await writer.finish()
            XCTAssertEqual(bytes, retained)
            let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
            defer { try? TelegramUploadFileIO.discard(file) }
            XCTAssertEqual(try XCTUnwrap(file.video).duration, 60, accuracy: 0.001)
            XCTAssertEqual(file.metadata?.roundVideo?.nativeDuration, 60)
        } catch { XCTFail("Retained cap recording unavailable: \(error)") }
    }
    // Catches trusting an audio buffer whose PCM format and actual sample timing disagree.
    func testMismatchedPCMTimingIsRefusedBeforeEncoding() async throws {
        let writer = try TelegramRoundVideoCaptureWriter(); defer { writer.cancel() }
        try await writer.appendVideo(roundCapturePixels(), at: .zero)
        let source = try roundCaptureAudio(offset: 0, count: 1470)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 22_050), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var changed: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: source,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &changed), noErr)
        do { try await writer.appendAudio(try XCTUnwrap(changed)); XCTFail("Mismatched PCM timing admitted") }
        catch { XCTAssertEqual(error as? TelegramRoundVideoCaptureError, .invalidSample) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.directory.path))
    }
    // Catches invoking native startWriting again when the first video append must retry.
    func testInitialVideoBackpressureRetriesWithoutRestartingNativeWriter() async throws {
        let readiness = FirstVideoBackpressure()
        let writer = try TelegramRoundVideoCaptureWriter(isVideoReady: { readiness.isReady($0) })
        defer { writer.cancel() }
        do {
            try await roundCaptureFeed(writer)
            let bytes = try await writer.finish()
            let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
            defer { try? TelegramUploadFileIO.discard(file) }
            XCTAssertEqual(file.video?.width, 300)
            XCTAssertEqual(try XCTUnwrap(file.video).duration, 1, accuracy: 0.001)
        } catch { XCTFail("Initial backpressure destroyed native recording: \(error)") }
    }
    // Catches a substituted output escaping no-follow checks or deleting its external target.
    func testSymlinkOutputIsRefusedAndExternalTargetSurvives() async throws {
        let writer = try TelegramRoundVideoCaptureWriter(); defer { writer.cancel() }
        try await roundCaptureFeed(writer)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = Data([11,22,33,44]); try marker.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let output = writer.directory.appendingPathComponent("capture.mp4")
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: outside)
        do { _ = try await writer.finish(); XCTFail("Substituted output returned bytes") }
        catch { XCTAssertEqual(error as? TelegramRoundVideoCaptureError, .invalidRecording) }
        XCTAssertEqual(try Data(contentsOf: outside), marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.directory.path))
    }
    // Catches abandoning an idle private stage when its owner is released without cancel.
    func testDeinitializationRemovesOwnedIdleStage() throws {
        var writer: TelegramRoundVideoCaptureWriter? = try TelegramRoundVideoCaptureWriter()
        let directory = try XCTUnwrap(writer).directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        writer = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    // Catches cancellation leaving an MP4 behind or publishing bytes from a cancelled writer.
    func testCancelIsTerminalBeforeAndAfterSamples() async throws {
        for feed in [false,true] {
            let writer = try TelegramRoundVideoCaptureWriter()
            if feed { try? await roundCaptureFeed(writer) }
            writer.cancel()
            do { _ = try await writer.finish(); XCTFail("Cancelled writer returned bytes") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.directory.path))
        }
    }
}

@MainActor func roundCaptureFeed(_ writer: TelegramRoundVideoCaptureWriter, frames: Int = 30) async throws {
    for frame in 0..<frames {
        try await writer.appendVideo(roundCapturePixels(), at: CMTime(value: Int64(frame), timescale: 30))
        try await writer.appendAudio(roundCaptureAudio(offset: frame * 1470, count: 1470))
    }
}
@MainActor func roundCapturePixels() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 600, 400, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
        let buffer else { throw RoundCaptureFixtureError.native }
    CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw RoundCaptureFixtureError.native }
    let bytes = address.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<400 { for x in 0..<600 {
        let p = y * stride + x * 4
        bytes[p] = x >= 300 && x < 500 ? 255 : 0
        bytes[p+1] = x < 100 || x >= 500 ? 255 : 0
        bytes[p+2] = x >= 100 && x < 300 ? 255 : 0
        bytes[p+3] = 255
    } }
    return buffer
}
@MainActor func roundCaptureAudio(offset: Int, count: Int, rate: Int = 44_100) throws -> CMSampleBuffer {
    var stream = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
        mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &stream, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw RoundCaptureFixtureError.native }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count*2,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count*2, flags: 0,
        blockBufferOut: &block) == noErr, let block else { throw RoundCaptureFixtureError.native }
    let silence = Data(repeating: 0, count: count*2)
    guard silence.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count*2) }) == noErr else { throw RoundCaptureFixtureError.native }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: CMTime(value: Int64(offset), timescale: Int32(rate)), decodeTimeStamp: .invalid)
    var size = 2, sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw RoundCaptureFixtureError.native }
    return sample
}
private enum RoundCaptureFixtureError: Error { case native }

private final class FirstVideoBackpressure: @unchecked Sendable {
    private let lock = NSLock()
    private var withheld = false
    func isReady(_ input: AVAssetWriterInput) -> Bool {
        lock.withLock {
            if !withheld { withheld = true; return false }
            return input.isReadyForMoreMediaData
        }
    }
}
