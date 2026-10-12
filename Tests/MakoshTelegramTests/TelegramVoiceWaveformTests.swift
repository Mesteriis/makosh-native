import Foundation
import XCTest
@testable import MakoshTelegram

final class TelegramVoiceWaveformTests: XCTestCase {
    // Refusing short PCM or including an incomplete encoder packet changes the recorded envelope.
    func testSilenceAndIncompletePacketsProduceOneHundredZeroValues() throws {
        for count in [1, 959, 960, 1_000, 48_000] {
            XCTAssertEqual(try TelegramVoiceWaveform.make(samples: [Int16](repeating: 0, count: count)), Data(repeating: 0, count: 63))
        }
        var tail = [Int16](repeating: 0, count: 1_000)
        for index in 900..<1_000 { tail[index] = .max }
        XCTAssertEqual(try TelegramVoiceWaveform.make(samples: tail), Data(repeating: 0, count: 63))
    }

    // The reference's virtual zero before each peak affects positions in a short recording.
    func testShortRecordingRetainsReferencePeakPositions() throws {
        let packed = try TelegramVoiceWaveform.make(samples: [Int16](repeating: 3_000, count: 960))
        var expected = [UInt8](repeating: 0, count: 100)
        for index in [5, 16, 27, 38, 50, 61, 72, 83, 94] { expected[index] = 18 }
        XCTAssertEqual(try values(packed), expected)
    }

    // Running-maximum normalization differs from an average of the independent bins.
    func testEarlyAndLateImpulseHaveReferenceNormalizationAndExactPacking() throws {
        var early = [Int16](repeating: 0, count: 48_000)
        for index in 0..<100 { early[index] = 3_000 }
        var earlyBytes = Data(repeating: 0, count: 63); earlyBytes[0] = 0x11
        XCTAssertEqual(try TelegramVoiceWaveform.make(samples: early), earlyBytes)
        var late = [Int16](repeating: 0, count: 48_000)
        for index in 47_900..<48_000 { late[index] = 3_000 }
        var lateBytes = Data(repeating: 0, count: 63); lateBytes[61] = 0x80; lateBytes[62] = 0x0f
        XCTAssertEqual(try TelegramVoiceWaveform.make(samples: late), lateBytes)
    }

    // Peak windows continue across encoder packets; resetting at960 loses this impulse.
    func testPeakWindowContinuesAcrossPacketBoundary() throws {
        var pcm = [Int16](repeating: 0, count: 1_920); pcm[999] = 3_000
        var expected = Data(repeating: 0, count: 63); expected[31] = 0x7c
        XCTAssertEqual(try TelegramVoiceWaveform.make(samples: pcm), expected)
    }

    // Quantization must be integral and handle Int16.min without overflow.
    func testConstantSignalsAndSignedMinimumHaveIntegralFiveBitValues() throws {
        for (sample, value): (Int16, UInt8) in [(1_000, 12), (3_000, 17), (.max, 17), (.min, 17)] {
            let packed = try TelegramVoiceWaveform.make(samples: [Int16](repeating: sample, count: 48_000))
            XCTAssertEqual(try values(packed), [UInt8](repeating: value, count: 100))
        }
    }

    // This leaf must enforce the recording bounds even when called outside the codec entry point.
    func testEmptyAndOversizedPCMRefused() {
        XCTAssertThrowsError(try TelegramVoiceWaveform.make(samples: [])) { XCTAssertEqual($0 as? TelegramRecordedVoiceError, .invalidPCM) }
        XCTAssertThrowsError(try TelegramVoiceWaveform.make(samples: [Int16](repeating: 0, count: 28_800_001))) {
            XCTAssertEqual($0 as? TelegramRecordedVoiceError, .invalidPCM)
        }
    }

    func testMaximumRecordingLengthRemainsSupported() throws {
        let packed = try TelegramVoiceWaveform.make(samples: [Int16](repeating: 0, count: 28_800_000))
        XCTAssertEqual(packed, Data(repeating: 0, count: 63))
    }

    func testPreCancelledWaveformWorkRefused() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try TelegramVoiceWaveform.make(samples: [1])
        }
        do { _ = try await task.value; XCTFail("Waveform ignored cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    // An independent bit-at-a-time reader checks cross-byte ordering and zero padding.
    private func values(_ packed: Data) throws -> [UInt8] {
        XCTAssertEqual(packed.count, 63)
        guard packed.count == 63 else { throw TelegramRecordedVoiceError.invalidRecording }
        XCTAssertEqual(packed[62] & 0xf0, 0)
        return (0..<100).map { index in
            var result: UInt8 = 0
            for bit in 0..<5 {
                let position = index * 5 + bit
                if packed[position / 8] & (1 << (position % 8)) != 0 { result |= 1 << bit }
            }
            return result
        }
    }
}
