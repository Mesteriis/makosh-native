import XCTest
import AVFoundation
import CoreVideo
@testable import MakoshTelegram

@MainActor
final class TelegramNativePlaybackEngineTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func wav(_ url: URL) throws {
        // Self-contained mono PCM, one second of silence; no external encoder or personal fixture.
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); word(UInt32(36 + 16000)); ascii("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8000))
        word(UInt32(16000)); word(UInt16(2)); word(UInt16(16)); ascii("data")
        word(UInt32(16000)); data.append(Data(repeating: 0, count: 16000))
        try data.write(to: url)
    }

    private func mp4(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let address = CVPixelBufferGetBaseAddress(pixels) {
            memset(address, 0, CVPixelBufferGetBytesPerRow(pixels) * 32)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<10 {
            var waits = 0
            while !input.isReadyForMoreMediaData {
                guard waits < 500, writer.status == .writing else { throw TelegramNativePlaybackError.unavailable }
                try await Task.sleep(for: .milliseconds(10)); waits += 1
            }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func testAssetPolicyForbidsAllNestedReferences() throws {
        let asset = TelegramNativePlaybackEngine.restrictedAsset(file: try directory().appendingPathComponent("synthetic.mov"))
        XCTAssertEqual(asset.referenceRestrictions, .forbidAll)
    }

    func testActualWAVLoadsWithoutAutoplayAndStopDetachesPlayer() async throws {
        let url = try directory().appendingPathComponent("synthetic.wav")
        try wav(url)
        let engine = TelegramNativePlaybackEngine()
        let info = try await engine.load(file: url, kind: .voice) { _ in }
        XCTAssertEqual(info.duration, 1, accuracy: 0.05)
        XCTAssertFalse(info.hasVideo)
        let player = try XCTUnwrap(engine.player)
        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(player.allowsExternalPlayback)
        engine.setVolume(2); XCTAssertEqual(player.volume, 1)
        engine.setVolume(-1); XCTAssertEqual(player.volume, 0)
        engine.seek(seconds: .nan)
        engine.stop()
        XCTAssertNil(engine.player)
        XCTAssertNil(player.currentItem)
        engine.stop()
    }

    func testActualMP4RequiresVideoClassification() async throws {
        let url = try directory().appendingPathComponent("synthetic.mp4")
        try await mp4(url)
        let engine = TelegramNativePlaybackEngine()
        let info = try await engine.load(file: url, kind: .roundVideo) { _ in }
        XCTAssertTrue(info.hasVideo)
        XCTAssertGreaterThan(info.duration, 0)
        XCTAssertEqual(engine.player?.rate, 0)
        engine.stop()
        await assertRejected(engine, url: url, kind: .audio)
    }

    func testCorruptAndMismatchedTrackFailSafely() async throws {
        let root = try directory()
        let bad = root.appendingPathComponent("corrupt.mp4")
        try Data("not media".utf8).write(to: bad)
        let engine = TelegramNativePlaybackEngine()
        await assertRejected(engine, url: bad, kind: .video)
        let audio = root.appendingPathComponent("synthetic.wav")
        try wav(audio)
        await assertRejected(engine, url: audio, kind: .video)
        await assertRejected(engine, url: root, kind: .voice)
        await assertRejected(engine, url: try XCTUnwrap(URL(string: "https://example.invalid/media")), kind: .audio)
    }

    func testCancelledLoadNeverPublishesPlayerOrEvents() async throws {
        let url = try directory().appendingPathComponent("synthetic.wav")
        try wav(url)
        let engine = TelegramNativePlaybackEngine()
        var events = 0
        let task = Task { @MainActor in
            try await engine.load(file: url, kind: .audio) { _ in events += 1 }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Expected safe cancellation") }
        XCTAssertNil(engine.player)
        XCTAssertEqual(events, 0)
    }

    #if DEBUG
    func testSyntheticOggOpusNativeCompatibility() async throws {
        let url = try directory().appendingPathComponent("synthetic.ogg")
        try await TelegramSyntheticPlaybackFixtures.write(kind: .voice, to: url)
        let engine = TelegramNativePlaybackEngine()
        let info = try await engine.load(file: url, kind: .voice) { _ in }
        // Native Ogg duration reporting varies between OS codec versions.
        XCTAssertGreaterThan(info.duration, 0)
        XCTAssertLessThan(info.duration, 30)
        XCTAssertFalse(info.hasVideo)
        XCTAssertEqual(engine.player?.rate, 0)
        engine.stop()
    }
    #endif

    private func assertRejected(_ engine: TelegramNativePlaybackEngine, url: URL, kind: TelegramPlaybackKind) async {
        do { _ = try await engine.load(file: url, kind: kind) { _ in }; XCTFail("Expected rejection") }
        catch let error as TelegramNativePlaybackError {
            XCTAssertEqual(error, .unavailable)
            XCTAssertFalse(error.localizedDescription.contains(url.path))
        } catch { XCTFail("Unexpected error type") }
        XCTAssertNil(engine.player)
    }
}
