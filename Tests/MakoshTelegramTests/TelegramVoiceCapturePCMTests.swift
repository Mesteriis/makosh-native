import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramVoiceCapturePCMTests: XCTestCase {
    // Wrong conversion/endian handling or dropped partial frames changes the captured original PCM.
    func testNativeCAFReadPreservesEverySignedSampleAndCleansStage() async throws {
        let stage = try makeStage()
        defer { stage.discard() }
        let expected: [Int16] = [-32_768, -4_096, -1, 0, 1, 4_096, 32_767]
        try writeCAF(stage.url, samples: expected)
        try stage.seal()
        var info = stat()
        XCTAssertEqual(lstat(stage.directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(stage.url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let actual = try await stage.consume()
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.directory.path))
        do { _ = try await stage.consume(); XCTFail("Consumed recording reused") } catch {}
    }

    // Native decoders can normalize a wrong format; capture must refuse rather than silently resample it.
    func testWrongRateChannelsDepthEmptyAndMalformedCAFRefuseAndClean() async throws {
        for (rate, channels, format) in [(44_100.0, 1, AVAudioCommonFormat.pcmFormatInt16),
                                          (48_000.0, 2, .pcmFormatInt16), (48_000.0, 1, .pcmFormatFloat32)] {
            let stage = try makeStage()
            defer { stage.discard() }
            try writeCAF(stage.url, samples: [1, 2, 3], rate: rate, channels: AVAudioChannelCount(channels), common: format)
            try stage.seal()
            await assertRefusedAndClean(stage)
        }
        for bytes in [Data(), Data("caff-invalid".utf8)] {
            let stage = try makeStage()
            defer { stage.discard() }
            try bytes.write(to: stage.url)
            try stage.seal()
            await assertRefusedAndClean(stage)
        }
        let empty = try makeStage()
        defer { empty.discard() }
        try writeCAF(empty.url, samples: [])
        try empty.seal()
        await assertRefusedAndClean(empty)
    }

    // A symlink, relaxed permissions, or replacement of the sealed inode must not reach native decoding.
    func testOwnershipChangesRefuseWithoutReadingOutsideStage() async throws {
        for change in 0..<7 {
            let stage = try makeStage()
            defer { stage.discard() }
            try writeCAF(stage.url, samples: [1, 2, 3])
            try stage.seal()
            switch change {
            case 0:
                try FileManager.default.removeItem(at: stage.url)
                try FileManager.default.createSymbolicLink(at: stage.url, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
            case 1: XCTAssertEqual(chmod(stage.url.path, 0o644), 0)
            case 2: XCTAssertEqual(chmod(stage.directory.path, 0o755), 0)
            case 3:
                let replacement = stage.directory.appendingPathComponent("replacement.caf")
                try writeCAF(replacement, samples: [9, 9, 9])
                XCTAssertEqual(chmod(replacement.path, 0o600), 0)
                XCTAssertEqual(rename(replacement.path, stage.url.path), 0)
            case 4:
                let handle = try FileHandle(forWritingTo: stage.url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0xff]))
                try handle.close()
            case 5: XCTAssertEqual(chmod(stage.directory.path, 0), 0)
            default:
                let handle = try FileHandle(forWritingTo: stage.url)
                let end = try handle.seekToEnd()
                try handle.seek(toOffset: end - 1)
                try handle.write(contentsOf: Data([0xff]))
                try handle.close()
                var times = [timeval(tv_sec: 1, tv_usec: 0), timeval(tv_sec: 1, tv_usec: 0)]
                XCTAssertEqual(utimes(stage.url.path, &times), 0)
            }
            await assertRefusedAndClean(stage)
        }
    }

    // Cancellation must not emit captured bytes, and must still remove the owned temporary recording.
    func testPrecancelledConsumptionCleansStage() async throws {
        let stage = try makeStage()
        defer { stage.discard() }
        try writeCAF(stage.url, samples: [1, 2, 3])
        try stage.seal()
        let task = Task { () throws -> [Int16] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await stage.consume()
        }
        do { _ = try await task.value; XCTFail("Cancelled PCM returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.directory.path))
    }

    // Abandoned and explicitly cancelled sessions must not leave plaintext CAF on disk.
    func testDiscardAndDeinitCleanUnconsumedStage() throws {
        var stage: TelegramVoiceCapturePCM? = try makeStage()
        let first = try XCTUnwrap(stage)
        try writeCAF(first.url, samples: [1])
        first.discard(); first.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        stage = try makeStage()
        let directory = try XCTUnwrap(stage?.directory)
        try writeCAF(try XCTUnwrap(stage?.url), samples: [1])
        stage = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // An incomplete/trailing CAF extent must not be silently ignored by the native reader.
    func testTrailingAndTruncatedCAFRefuseAndClean() async throws {
        for truncated in [false, true] {
            let stage = try makeStage()
            defer { stage.discard() }
            try writeCAF(stage.url, samples: [1, 2, 3])
            var bytes = try Data(contentsOf: stage.url)
            if truncated { bytes.removeLast() } else { bytes.append(0xff) }
            try bytes.write(to: stage.url)
            try stage.seal()
            await assertRefusedAndClean(stage)
        }
    }

    // The ten-minute boundary accepts every final sample, but refuses an extra one rather than trimming it.
    func testExactMaximumAndOneSampleOverLimit() async throws {
        for count in [28_800_000, 28_800_001] {
            let stage = try makeStage()
            defer { stage.discard() }
            var pcm = [Int16](repeating: -123, count: count)
            pcm[count - 1] = 32_767
            try writeCAF(stage.url, samples: pcm)
            try stage.seal()
            if count == 28_800_000 {
                let actual = try await stage.consume()
                XCTAssertEqual(actual.count, 28_800_000)
                XCTAssertEqual(actual.first, -123)
                XCTAssertEqual(actual.last, 32_767)
                XCTAssertFalse(FileManager.default.fileExists(atPath: stage.directory.path))
            } else { await assertRefusedAndClean(stage) }
        }
    }

    private func makeStage() throws -> TelegramVoiceCapturePCM {
        let stage = try TelegramVoiceCapturePCM()
        let directory = stage.directory
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramVoiceCaptureError.unavailable }
        addTeardownBlock {
            fchmod(fd, 0o700); Darwin.close(fd)
            try? FileManager.default.removeItem(at: directory)
        }
        return stage
    }


    private func assertRefusedAndClean(_ stage: TelegramVoiceCapturePCM) async {
        do { _ = try await stage.consume(); XCTFail("Invalid capture accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.directory.path))
    }

    private func writeCAF(_ url: URL, samples: [Int16], rate: Double = 48_000,
                          channels: AVAudioChannelCount = 1,
                          common: AVAudioCommonFormat = .pcmFormatInt16) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: rate, channels: channels, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: common, interleaved: true)
        defer { file.close() }
        guard !samples.isEmpty else { return }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let data = buffer.int16ChannelData {
            for index in 0..<(samples.count * Int(channels)) { data[0][index] = samples[index / Int(channels)] }
        } else if let data = buffer.floatChannelData {
            for index in 0..<(samples.count * Int(channels)) { data[0][index] = Float(samples[index / Int(channels)]) / 32_768 }
        } else { XCTFail("Unsupported fixture format") }
        try file.write(from: buffer)
    }
}
