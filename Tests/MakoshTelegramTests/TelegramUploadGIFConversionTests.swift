import XCTest
import Foundation
import AVFoundation
import CoreVideo
import CryptoKit
@testable import MakoshTelegram

@MainActor
final class TelegramUploadGIFConversionTests: XCTestCase {
    private func stage(_ bytes: Data) async throws -> TelegramUploadFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("opaque.bin")
        try bytes.write(to: source)
        let file = try await TelegramUploadFileIO.stage(source, mode: .file)
        addTeardownBlock { try TelegramUploadFileIO.discard(file) }
        try FileManager.default.removeItem(at: source)
        return file
    }

    private struct Frame {
        let time: Double
        let center: [Int]
        let corner: [Int]
    }

    private func frames(_ file: TelegramUploadFile) async throws -> [Frame] {
        // Owned payload paths intentionally have no extension. Tell the native
        // reader the independently expected container rather than a path suffix.
        let asset = AVURLAsset(url: file.url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_H264)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetWidth(pixels), Int(file.pixelWidth ?? 0))
            XCTAssertEqual(CVPixelBufferGetHeight(pixels), Int(file.pixelHeight ?? 0))
            guard CVPixelBufferGetWidth(pixels) >= 11, CVPixelBufferGetHeight(pixels) >= 7,
                  CVPixelBufferGetBytesPerRow(pixels) >= CVPixelBufferGetWidth(pixels) * 4,
                  CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else {
                XCTFail("Decoded frame cannot safely supply the literal sample coordinates")
                throw TelegramUploadGIFError.invalidGIF
            }
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            func rgb(_ x: Int, _ y: Int) -> [Int] {
                let offset = y * row + x * 4
                return [Int(base[offset + 2]), Int(base[offset + 1]), Int(base[offset])]
            }
            result.append(.init(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                center: rgb(10, 6), corner: rgb(3, 3)))
        }
        XCTAssertEqual(reader.status, .completed)
        return result
    }

    private func assertRGB(_ actual: [Int], _ expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 30, file: file, line: line) }
    }

    // Catches GIF relabeling, lost frame timing/colors, missing last-frame repeat and raw modification.
    func testOwnedGIFProducesIndependentH264WithReferenceSampleTimes() async throws {
        let raw = try await stage(uploadGIFTimingFixture)
        let expected = TelegramUploadGIFInfo(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.4])
        let digest = SHA256.hash(data: uploadGIFTimingFixture).map { String(format: "%02x", $0) }.joined()
        let output = try await TelegramUploadGIFIO.convert(raw, expected: expected, expectedPlaintextSHA256: digest)
        defer { try? TelegramUploadFileIO.discard(output) }
        try TelegramUploadFileIO.validateOwnedStage(output)
        XCTAssertEqual(output.mode, .video); XCTAssertEqual(output.name, "opaque.mp4")
        XCTAssertNotEqual(output.id, raw.id); XCTAssertNotEqual(output.directory, raw.directory)
        XCTAssertEqual(output.pixelWidth, 32); XCTAssertEqual(output.pixelHeight, 16)
        XCTAssertGreaterThan(output.size, 0); XCTAssertLessThanOrEqual(output.size, 128 * 1024 * 1024)
        let video = try XCTUnwrap(output.video)
        XCTAssertFalse(video.hasAudio); XCTAssertTrue(video.inCollage)
        let measured = try await AVURLAsset(url: output.url,
            options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"]).load(.duration).seconds
        XCTAssertGreaterThan(measured, 0.65)
        XCTAssertEqual(video.duration, Double(Float32(measured)))
        let actual = try await frames(output)
        XCTAssertEqual(actual.count, 4)
        for (frame, time) in zip(actual, [0.0, 0.05, 0.25, 0.65]) {
            XCTAssertEqual(frame.time, time, accuracy: 1.0 / 600)
        }
        for (frame, color) in zip(actual, [[255, 0, 0], [0, 255, 0], [0, 0, 255], [0, 0, 255]]) {
            assertRGB(frame.center, color)
        }
        XCTAssertEqual(try Data(contentsOf: raw.url), uploadGIFTimingFixture)
        XCTAssertNotEqual(try Data(contentsOf: output.url), uploadGIFTimingFixture)
    }

    // Catches replacing the Float-to-Double boundary with an intuitive decimal comparison.
    func testPointThirtyThreeLastDelayRepeatsButPointThirtyTwoDoesNot() async throws {
        for (delay, duration, times) in [(UInt16(33), Float(0.33), [0.0, 0.05, 0.38]),
                                       (UInt16(32), Float(0.32), [0.0, 0.05])] {
            let raw = try await stage(uploadGIFFixture([.init(color: 1, delay: 5), .init(color: 3, delay: delay)]))
            let output = try await TelegramUploadGIFIO.convert(raw,
                expected: .init(width: 32, height: 16, frameDurations: [0.05, duration]))
            defer { try? TelegramUploadFileIO.discard(output) }
            let actual = try await frames(output)
            XCTAssertEqual(actual.count, times.count)
            for (frame, time) in zip(actual, times) { XCTAssertEqual(frame.time, time, accuracy: 1.0 / 600) }
        }
    }

    // Catches stretching the patch to the canvas or losing the preceding composited background.
    func testPartialFramesRetainCanvasAndPlacement() async throws {
        let raw = try await stage(uploadGIFFixture([.init(color: 1, delay: 5),
            .init(color: 3, delay: 20, x: 8, y: 4, width: 8, height: 4)]))
        let output = try await TelegramUploadGIFIO.convert(raw,
            expected: .init(width: 32, height: 16, frameDurations: [0.05, 0.2]))
        defer { try? TelegramUploadFileIO.discard(output) }
        let actual = try await frames(output)
        XCTAssertEqual(actual.count, 2)
        if actual.count == 2 {
            assertRGB(actual[0].center, [255, 0, 0])
            assertRGB(actual[1].center, [0, 0, 255])
            assertRGB(actual[1].corner, [255, 0, 0])
        }
        XCTAssertEqual(output.pixelWidth, 32); XCTAssertEqual(output.pixelHeight, 16)
    }

    // Catches dropping a valid one-frame source or publishing a zero-duration MP4.
    func testSingleFrameGIFProducesPlayableOwnedVideo() async throws {
        let bytes = uploadGIFFixture([.init(color: 1, delay: nil)])
        let raw = try await stage(bytes)
        let output = try await TelegramUploadGIFIO.convert(raw,
            expected: .init(width: 32, height: 16, frameDurations: [0.1]))
        defer { try? TelegramUploadFileIO.discard(output) }
        let actual = try await frames(output)
        XCTAssertEqual(actual.count, 1)
        if let first = actual.first {
            XCTAssertEqual(first.time, 0, accuracy: 1.0 / 600)
            assertRGB(first.center, [255, 0, 0])
        }
        XCTAssertGreaterThan(try XCTUnwrap(output.video).duration, 0)
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    // Catches retaining a disposed patch instead of clearing it to background.
    func testRestoreBackgroundDisposalClearsOnlyPreviousPatch() async throws {
        let raw = try await stage(uploadGIFFixture([.init(color: 1, delay: 5),
            .init(color: 3, delay: 20, x: 8, y: 4, width: 8, height: 4, disposal: 2),
            .init(color: 2, delay: 20, x: 20, y: 8, width: 8, height: 4)]))
        let output = try await TelegramUploadGIFIO.convert(raw,
            expected: .init(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.2]))
        defer { try? TelegramUploadFileIO.discard(output) }
        let actual = try await frames(output)
        XCTAssertEqual(actual.count, 3)
        if actual.count == 3 {
            assertRGB(actual[1].center, [0, 0, 255])
            assertRGB(actual[2].center, [0, 0, 0])
            assertRGB(actual[2].corner, [255, 0, 0])
        }
    }

    // Catches clearing disposal3 to black instead of restoring the preceding canvas.
    func testRestorePreviousDisposalRestoresUnderlyingCanvas() async throws {
        let raw = try await stage(uploadGIFFixture([.init(color: 1, delay: 5),
            .init(color: 3, delay: 20, x: 8, y: 4, width: 8, height: 4, disposal: 3),
            .init(color: 2, delay: 20, x: 20, y: 8, width: 8, height: 4)]))
        let output = try await TelegramUploadGIFIO.convert(raw,
            expected: .init(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.2]))
        defer { try? TelegramUploadFileIO.discard(output) }
        let actual = try await frames(output)
        XCTAssertEqual(actual.count, 3)
        if actual.count == 3 {
            assertRGB(actual[1].center, [0, 0, 255])
            assertRGB(actual[2].center, [255, 0, 0])
            assertRGB(actual[2].corner, [255, 0, 0])
        }
    }

    // Catches a codec-only check that creates a derivative from unbound or changed source facts.
    func testMismatchedSourceFactsOrDigestFailBeforePublishingDerivative() async throws {
        let raw = try await stage(uploadGIFTimingFixture)
        for expected in [TelegramUploadGIFInfo(width: 31, height: 16, frameDurations: [0.05, 0.2, 0.4]),
                         .init(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.3])] {
            do { _ = try await TelegramUploadGIFIO.convert(raw, expected: expected); XCTFail("Source facts must match") }
            catch let error as TelegramUploadGIFError { XCTAssertEqual(error, .invalidGIF) }
        }
        for digest in [String(repeating: "a", count: 64), String(repeating: "A", count: 64), ""] {
            do {
                _ = try await TelegramUploadGIFIO.convert(raw,
                    expected: .init(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.4]), expectedPlaintextSHA256: digest)
                XCTFail("Digest must match held source bytes")
            } catch let error as TelegramUploadFileError { XCTAssertEqual(error, .unavailable) }
        }
        XCTAssertEqual(try Data(contentsOf: raw.url), uploadGIFTimingFixture)
    }

    // Catches treating a cancelled conversion as success and consuming its original stage.
    func testAlreadyCancelledConversionLeavesOriginalUsable() async throws {
        let raw = try await stage(uploadGIFTimingFixture)
        let task = Task { try await TelegramUploadGIFIO.convert(raw,
            expected: .init(width: 32, height: 16, frameDurations: [0.05, 0.2, 0.4])) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled conversion must throw") }
        catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: raw.url), uploadGIFTimingFixture)
    }
}
