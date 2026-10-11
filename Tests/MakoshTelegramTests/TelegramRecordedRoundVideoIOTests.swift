import XCTest
import Foundation
import AVFoundation
import AudioToolbox
import CoreVideo
import CryptoKit
import Darwin
@testable import MakoshTelegram

@MainActor
final class TelegramRecordedRoundVideoIOTests: XCTestCase {
    // Catches replacing the recorder's real geometry with Telegram's fixed200x200 wire geometry.
    func testExplicitRecordingPreservesBytesAndActualPrivateVideoFacts() async throws {
        let bytes = try await fixture(side: 300)
        let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
        defer { try? TelegramUploadFileIO.discard(file) }
        XCTAssertEqual(file.name, "RoundVideo.mp4"); XCTAssertEqual(file.mode, .video)
        XCTAssertEqual(file.pixelWidth, 300); XCTAssertEqual(file.pixelHeight, 300)
        let video = try XCTUnwrap(file.video)
        XCTAssertEqual(video.width, 300); XCTAssertEqual(video.height, 300)
        XCTAssertEqual(video.duration, 1, accuracy: 0.001)
        XCTAssertTrue(video.hasAudio); XCTAssertFalse(video.inCollage)
        let round = try XCTUnwrap(file.metadata?.roundVideo)
        XCTAssertFalse(round.isOneTime)
        XCTAssertEqual(round.plaintextSHA256, digest(bytes))
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        var info = stat()
        XCTAssertEqual(lstat(file.directory.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(file.url.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let inspected = try await TelegramRecordedRoundVideoIO.inspect(file)
        XCTAssertEqual(inspected.plaintextSHA256, digest(bytes))
        XCTAssertEqual(inspected.nativeDuration, 1)
        XCTAssertEqual(round.nativeDuration, 1)
        try await assertNativeFormats(file.url, side: 300)
    }

    // Catches losing frozen once intent, and classifying a square picker file as a recorder message.
    func testOnceIntentSurvivesButIdenticalPickedBytesStayOrdinaryVideo() async throws {
        let bytes = try await fixture()
        let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes, isOneTime: true)
        defer { try? TelegramUploadFileIO.discard(file) }
        XCTAssertEqual(file.metadata?.roundVideo?.isOneTime, true)
        let root = try directory(), source = root.appendingPathComponent("picked.mp4")
        try bytes.write(to: source)
        let picked = try await TelegramUploadFileIO.stage(source, mode: .video)
        defer { try? TelegramUploadFileIO.discard(picked) }
        XCTAssertNil(picked.metadata)
        XCTAssertEqual(picked.video?.width, picked.video?.height)
        XCTAssertEqual(try Data(contentsOf: picked.url), bytes)
    }

    // Catches trusting a restored descriptor rather than the actual encoded file or preserving collage mode.
    func testInspectionRefusesChangedFrozenFactsDigestAndRoles() async throws {
        let bytes = try await fixture()
        let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
        defer { try? TelegramUploadFileIO.discard(file) }
        let video = try XCTUnwrap(file.video)
        let altered = [
            TelegramUploadVideoMetadata(width: 31, height: 31, duration: video.duration, hasAudio: true, inCollage: false),
            .init(width: 32, height: 32, duration: 2, hasAudio: true, inCollage: false),
            .init(width: 32, height: 32, duration: video.duration, hasAudio: false, inCollage: false),
            .init(width: 32, height: 32, duration: video.duration, hasAudio: true, inCollage: true)
        ]
        for facts in altered { await assertInvalidInspection(copy(file, video: facts)) }
        let wrongHash: TelegramUploadMetadata = .roundVideo(.init(nativeDuration: 1, plaintextSHA256: String(repeating: "0", count: 64)))
        await assertInvalidInspection(copy(file, metadata: wrongHash))
        await assertInvalidInspection(copy(file, metadata: .roundVideo(.init(nativeDuration: 2, plaintextSHA256: digest(bytes)))))
        await assertInvalidInspection(copy(file, metadata: .some(nil)))
        let renamed = TelegramUploadFile(id: file.id, name: "picked.mp4", size: file.size, mode: file.mode,
            pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: file.url, directory: file.directory,
            video: file.video, metadata: file.metadata)
        await assertInvalidInspection(renamed)
        var damaged = bytes; damaged[damaged.startIndex] ^= 0xff
        try damaged.write(to: file.url)
        await assertInvalidInspection(file)
    }

    // Catches accepting a path alias or a widened stage permission before native media loading.
    func testInspectionRefusesSymlinkForeignPathAndNonprivateStage() async throws {
        let bytes = try await fixture(), root = try directory()
        let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
        defer { try? TelegramUploadFileIO.discard(file) }
        let foreign = root.appendingPathComponent("foreign.mp4"); try bytes.write(to: foreign)
        let alias = TelegramUploadFile(id: file.id, name: file.name, size: file.size, mode: file.mode,
            pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, url: foreign, directory: file.directory,
            video: file.video, metadata: file.metadata)
        await assertInvalidInspection(alias)
        XCTAssertEqual(chmod(file.url.path, 0o644), 0); await assertInvalidInspection(file)
        XCTAssertEqual(chmod(file.url.path, 0o600), 0)
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: foreign)
        await assertInvalidInspection(file)
        try FileManager.default.removeItem(at: file.url)
        XCTAssertEqual(chmod(foreign.path, 0o600), 0)
        XCTAssertEqual(link(foreign.path, file.url.path), 0)
        await assertInvalidInspection(file)
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
    }

    // Catches admitting missing/wrong audio, non-H264 media, MOV, or nonsquare physical frames.
    func testPreparationRefusesUnsupportedActualTracksAndContainerWithoutLeakingStage() async throws {
        for options in [Options(audio: false), Options(rate: 48_000), Options(channels: 2),
                        Options(codec: .hevc), Options(height: 16), Options(mov: true), Options(audioTrackCount: 2)] {
            let bytes = try await fixture(options: options)
            let before = try stages()
            await assertInvalidPreparation(bytes)
            XCTAssertEqual(try stages(), before)
        }
    }

    // Catches off-by-one duration/side bounds, using ceil before validation, or truncating a long recording.
    func testPhysicalDurationAndSquareSizeBoundariesUseActualNativeMedia() async throws {
        for (duration, side) in [(0.5, 32), (60.0, 32), (1.0, 1024)] {
            let bytes = try await fixture(side: side, duration: duration)
            let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
            defer { try? TelegramUploadFileIO.discard(file) }
            XCTAssertEqual(file.video?.width, Int32(side))
            XCTAssertEqual(try XCTUnwrap(file.video).duration, duration, accuracy: 0.001)
        }
        for (duration, side) in [(0.49, 32), (60.01, 32), (1.0, 1026)] {
            await assertInvalidPreparation(try await fixture(side: side, duration: duration))
        }
    }

    // Catches AVFoundation tolerating trailing/truncated box data, or copying a128MiB+1 input before refusing it.
    func testMalformedEmptyAndOversizedBytesDoNotPublishStages() async throws {
        let bytes = try await fixture()
        for data in [Data(), Data("not a movie".utf8), Data(bytes.dropLast()), bytes + Data(repeating: 0, count: 7)] {
            let before = try stages(); await assertInvalidPreparation(data); XCTAssertEqual(try stages(), before)
        }
        let before = try stages()
        await assertInvalidPreparation(Data(repeating: 0, count: 128 * 1024 * 1024 + 1))
        XCTAssertEqual(try stages(), before)
    }

    // Catches deriving wire duration from already-rounded Float32 facts, losing a fractional second above1.
    func testNativeDurationCeilsRawAssetBeforeFloat32Persistence() async throws {
        let bytes = try await fixture(duration: 1.00000001, timescale: 1_000_000_000)
        let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
        defer { try? TelegramUploadFileIO.discard(file) }
        XCTAssertEqual(file.video?.duration, 1)
        XCTAssertEqual(file.metadata?.roundVideo?.nativeDuration, 2)
        let facts = try await TelegramRecordedRoundVideoIO.inspect(file)
        XCTAssertEqual(facts.nativeDuration, 2)
    }

    // Catches checking only AVAsset headers while never decoding the actual compressed sample payload.
    func testCorruptCompressedPayloadWithIntactMovieAtomsIsRejected() async throws {
        var bytes = try await fixture()
        let marker = try XCTUnwrap(bytes.range(of: Data("mdat".utf8)))
        let start = marker.lowerBound - 4
        var size = bytes[start..<marker.lowerBound].reduce(0) { ($0 << 8) | Int($1) }, header = 8
        if size == 1 {
            guard marker.upperBound + 8 <= bytes.count else { throw RoundFixtureError.native }
            size = bytes[marker.upperBound..<(marker.upperBound + 8)].reduce(0) { ($0 << 8) | Int($1) }; header = 16
        }
        guard size > header, size <= bytes.count - start else { throw RoundFixtureError.native }
        bytes.replaceSubrange((start + header)..<(start + size), with: Data(repeating: 0, count: size - header))
        let before = try stages()
        await assertInvalidPreparation(bytes)
        XCTAssertEqual(try stages(), before)
    }

    // Catches launching private I/O or swallowing cancellation when the recording action has already ended.
    func testAlreadyCancelledPreparationAndInspectionPreserveOwnership() async throws {
        let bytes = try await fixture(), before = try stages()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
        }
        do { let file = try await cancelled.value; try? TelegramUploadFileIO.discard(file); XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try stages(), before)
        let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes)
        defer { try? TelegramUploadFileIO.discard(file) }
        let inspection = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TelegramRecordedRoundVideoIO.inspect(file)
        }
        do { _ = try await inspection.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        try TelegramUploadFileIO.discard(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path))
        try TelegramUploadFileIO.discard(file)
    }

    private func copy(_ file: TelegramUploadFile, video: TelegramUploadVideoMetadata? = nil,
                      metadata: TelegramUploadMetadata?? = nil) -> TelegramUploadFile {
        .init(id: file.id, name: file.name, size: file.size, mode: file.mode,
            pixelWidth: video?.width ?? file.pixelWidth, pixelHeight: video?.height ?? file.pixelHeight,
            url: file.url, directory: file.directory, video: video ?? file.video, metadata: metadata ?? file.metadata)
    }
    private func assertInvalidInspection(_ file: TelegramUploadFile, line: UInt = #line) async {
        do { _ = try await TelegramRecordedRoundVideoIO.inspect(file); XCTFail("Invalid recording accepted", line: line) }
        catch is TelegramUploadFileError {} catch { XCTFail("Unexpected error: \(error)", line: line) }
    }
    private func assertInvalidPreparation(_ bytes: Data, line: UInt = #line) async {
        do { let file = try await TelegramRecordedRoundVideoIO.prepare(bytes: bytes); try? TelegramUploadFileIO.discard(file); XCTFail("Invalid recording accepted", line: line) }
        catch is TelegramUploadFileError {} catch { XCTFail("Unexpected error: \(error)", line: line) }
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func stages() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("makosh-upload-") })
    }
    private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    private struct Options {
        var audio = true
        var rate = 44_100
        var channels = 1
        var codec = AVVideoCodecType.h264
        var height: Int?
        var mov = false
        var audioTrackCount = 1
    }

    private func fixture(side: Int = 32, duration: Double = 1, options: Options = Options(),
                         timescale: CMTimeScale = 60_000) async throws -> Data {
        try await recordedRoundVideoFixtureBytes(side: side, duration: duration, audio: options.audio,
            rate: options.rate, channels: options.channels, codec: options.codec, height: options.height, mov: options.mov,
            audioTrackCount: options.audioTrackCount, timescale: timescale)
    }
    private func assertNativeFormats(_ url: URL, side: Int) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
        let video = try XCTUnwrap(videos.first), audio = try XCTUnwrap(audios.first)
        let videoFormats = try await video.load(.formatDescriptions)
        let videoFormat = try XCTUnwrap(videoFormats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(videoFormat), kCMVideoCodecType_H264)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(videoFormat).width, Int32(side))
        let audioFormats = try await audio.load(.formatDescriptions)
        let audioFormat = try XCTUnwrap(audioFormats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioFormat), kAudioFormatMPEG4AAC)
        let stream = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)).pointee
        XCTAssertEqual(stream.mSampleRate, 44_100); XCTAssertEqual(stream.mChannelsPerFrame, 1)
    }
}

/// Native H264/AAC from synthetic pixels and silence; default duration1s, physical300square, no device.
@MainActor
func recordedRoundVideoFixtureBytes(side: Int = 300, duration: Double = 1, audio: Bool = true,
    rate: Int = 44_100, channels: Int = 1, codec: AVVideoCodecType = .h264,
    height: Int? = nil, mov: Bool = false, audioTrackCount: Int = 1,
    timescale: CMTimeScale = 60_000) async throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(mov ? "fixture.mov" : "fixture.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: mov ? .mov : .mp4)
        writer.movieTimeScale = timescale
        let actualHeight = height ?? side
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec,
            AVVideoWidthKey: side, AVVideoHeightKey: actualHeight])
        video.mediaTimeScale = timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: actualHeight])
        writer.add(video)
        let audioInputs = audio ? (0..<audioTrackCount).map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 64_000]) } : []
        for audio in audioInputs { writer.add(audio) }
        guard writer.startWriting() else { throw RoundFixtureError.native }
        writer.startSession(atSourceTime: .zero)
        do {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, side, actualHeight, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw RoundFixtureError.native }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 0, CVPixelBufferGetBytesPerRow(buffer) * actualHeight) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for time in [0.0, duration / 2] {
                try await roundFixtureWait(video, writer: writer)
                guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: timescale)) else { throw RoundFixtureError.native }
            }
            video.markAsFinished()
            if !audioInputs.isEmpty {
                let count = Int((duration * Double(rate)).rounded())
                for offset in stride(from: 0, to: count, by: 4096) {
                    let sample = try roundFixtureSilence(count: min(4096, count - offset), offset: offset, rate: rate, channels: channels)
                    for audio in audioInputs {
                        try await roundFixtureWait(audio, writer: writer)
                        guard audio.append(sample) else { throw RoundFixtureError.native }
                    }
                }
                for audio in audioInputs { audio.markAsFinished() }
            }
            writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: timescale))
            await writer.finishWriting()
            guard writer.status == .completed else { throw RoundFixtureError.native }
            return try Data(contentsOf: url)
        } catch {
            XCTFail("Synthetic writer failed (duration \(duration), side \(side), timescale \(timescale)): \(String(describing: writer.error))")
            writer.cancelWriting(); throw error
        }
    }

@MainActor
private func roundFixtureWait(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        var attempts = 0
        while !input.isReadyForMoreMediaData {
            guard attempts < 500, writer.status == .writing else { throw RoundFixtureError.native }
            try await Task.sleep(for: .milliseconds(10)); attempts += 1
        }
    }
@MainActor
private func roundFixtureSilence(count: Int, offset: Int, rate: Int, channels: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 2),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
            let format else { throw RoundFixtureError.native }
        var block: CMBlockBuffer?
        let size = count * channels * 2
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: size,
            flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw RoundFixtureError.native }
        let zeros = Data(repeating: 0, count: size)
        guard zeros.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
            offsetIntoDestination: 0, dataLength: size) }) == kCMBlockBufferNoErr else { throw RoundFixtureError.native }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: CMTime(value: Int64(offset), timescale: Int32(rate)), decodeTimeStamp: .invalid)
        var sampleSize = channels * 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
            let sample else { throw RoundFixtureError.native }
        return sample
    }

private enum RoundFixtureError: Error { case native }
