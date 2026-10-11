import Foundation
import XCTest
import COpus
@testable import MakoshTelegram

@MainActor final class TelegramRecordedVoiceCodecTests: XCTestCase {
    // Missing Opus encoding, wrong rate/channel/headers/preskip or EOS loses the source audio.
    func testEncodedVoiceHasReferenceFormatAndIndependentNativePlayback() async throws {
        let source = tone(count: 48_137)
        let data = try await TelegramRecordedVoiceCodec.encode(samples: source)
        let pages = try readPages(data)
        XCTAssertEqual(Array(pages[0].packet.prefix(10)), Array("OpusHead".utf8) + [1, 1])
        XCTAssertEqual(Array(pages[0].packet[12..<19]), [128, 187, 0, 0, 0, 0, 0]) //48k,gain0,map0
        XCTAssertEqual(pages[0].flags, 2)
        XCTAssertEqual(pages[0].granule, 0)
        XCTAssertEqual(pages[1].packet, Data("OpusTags".utf8) + Data([6, 0, 0, 0]) + Data("Makosh".utf8) + Data([0, 0, 0, 0]))
        XCTAssertEqual(pages[1].flags, 0)
        let skip = Int(pages[0].packet[10]) | Int(pages[0].packet[11]) << 8
        XCTAssertGreaterThan(skip, 0)
        XCTAssertLessThanOrEqual(skip, 960)
        XCTAssertEqual(pages.last?.granule, UInt64(48_137 + skip))
        XCTAssertEqual(pages.last?.flags, 4)
        for (index, page) in pages.enumerated() {
            XCTAssertEqual(page.sequence, UInt32(index))
            XCTAssertEqual(page.serial, pages[0].serial)
            if index >= 2 && index < pages.count - 1 {
                XCTAssertEqual(page.flags, 0)
                XCTAssertEqual(page.granule, UInt64((index - 1) * 960))
            }
        }
        let independent = try nativeDecode(pages: pages, skip: skip, count: source.count)
        XCTAssertGreaterThan(correlation(source, independent), 0.96)
        let decoded = try await TelegramRecordedVoiceCodec.decodeRecording(data)
        XCTAssertEqual(decoded, independent)
    }

    // Missing encoder-delay flush or end trim changes very short/non-frame-aligned recordings.
    func testSilenceAndPartialFramesRetainExactPCMCount() async throws {
        for count in [1, 119, 959, 960, 961, 1_920, 2_231] {
            let data = try await TelegramRecordedVoiceCodec.encode(samples: [Int16](repeating: 0, count: count))
            let decoded = try await TelegramRecordedVoiceCodec.decodeRecording(data)
            XCTAssertEqual(decoded.count, count)
            XCTAssertTrue(decoded.allSatisfy { abs(Int($0)) <= 1 })
        }
    }

    // A default/high bitrate instead of the selected reference setting inflates stored recordings.
    func testReferenceBitrateKeepsRealTwoSecondRecordingBounded() async throws {
        let data = try await TelegramRecordedVoiceCodec.encode(samples: tone(count: 96_000))
        let pages = try readPages(data)
        let payloadBytes = pages.dropFirst(2).reduce(0) { $0 + $1.packet.count }
        XCTAssertGreaterThan(payloadBytes, 3_000)
        XCTAssertLessThan(payloadBytes, 10_000)
    }

    // Invalid source size must fail before native allocation/encoding.
    func testEmptyAndOverTenMinutePCMRejected() async throws {
        for samples in [[], [Int16](repeating: 0, count: 28_800_001)] {
            do { _ = try await TelegramRecordedVoiceCodec.encode(samples: samples); XCTFail("Invalid PCM accepted") }
            catch { XCTAssertEqual(error as? TelegramRecordedVoiceError, .invalidPCM) }
        }
    }

    // Corruption/truncation must not silently produce a different voice recording.
    func testCorruptedTruncatedAndOversizedRecordingRejected() async throws {
        let data = try await TelegramRecordedVoiceCodec.encode(samples: tone(count: 2_000))
        var corrupted = data; corrupted[corrupted.count - 1] ^= 1
        for invalid in [Data(), Data(data.dropLast()), data + Data([0]), corrupted,
                        Data(repeating: 0, count: 20 * 1024 * 1024 + 1)] {
            await assertInvalid(invalid)
        }
    }

    // A valid CRC cannot bypass mono/rate/gain/version/header/sequence/serial/EOS limits.
    func testRechecksContainerSemanticsAfterChecksum() async throws {
        let data = try await TelegramRecordedVoiceCodec.encode(samples: tone(count: 2_000))
        let pages = try readPages(data)
        for (pageIndex, offset, replacement) in [(0, 28 + 8, UInt8(2)), (0, 28 + 9, 2),
            (0, 28 + 12, 0), (0, 28 + 16, 1), (0, 28 + 18, 1), (0, 5, 0),
            (1, 18, 9), (2, 14, 9), (2, 5, 1), (pages.count - 1, 5, 0),
            (pages.count - 1, 13, 0xff)] {
            var invalid = data
            let page = pages[pageIndex]
            invalid[page.start + offset] = replacement
            repairCRC(&invalid, start: page.start, end: page.end)
            await assertInvalid(invalid)
        }
    }

    // Cancellation must win before starting native work for either direction.
    func testPreCancelledOperationsDoNoCodecWork() async throws {
        let data = try await TelegramRecordedVoiceCodec.encode(samples: tone(count: 1_000))
        for decode in [false, true] {
            let task = Task { () throws -> Void in
                withUnsafeCurrentTask { $0?.cancel() }
                if decode { _ = try await TelegramRecordedVoiceCodec.decodeRecording(data) }
                else { _ = try await TelegramRecordedVoiceCodec.encode(samples: [1]) }
            }
            do { try await task.value; XCTFail("Cancellation ignored") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    private func assertInvalid(_ data: Data) async {
        do { _ = try await TelegramRecordedVoiceCodec.decodeRecording(data); XCTFail("Invalid Ogg accepted") }
        catch { XCTAssertEqual(error as? TelegramRecordedVoiceError, .invalidRecording) }
    }

    private func tone(count: Int) -> [Int16] {
        (0..<count).map { index in
            let phase: Double = Double(index) * 2.0 * Double.pi / 48_000.0
            let fundamental: Double = 12_000.0 * sin(phase * 440.0)
            let overtone: Double = 3_000.0 * sin(phase * 1_203.0)
            return Int16(fundamental + overtone)
        }
    }

    private func correlation(_ lhs: [Int16], _ rhs: [Int16]) -> Double {
        guard lhs.count == rhs.count else { return 0 }
        var cross = 0.0, left = 0.0, right = 0.0
        for (a, b) in zip(lhs, rhs) {
            cross += Double(a) * Double(b); left += Double(a) * Double(a); right += Double(b) * Double(b)
        }
        return cross / sqrt(left * right)
    }

    private struct Page {
        let start: Int, end: Int
        let flags: UInt8
        let granule: UInt64
        let serial: UInt32, sequence: UInt32
        let packet: Data
    }

    /// Independent test reader and bit-at-a-time CRC; never calls the production Ogg parser.
    private func readPages(_ data: Data) throws -> [Page] {
        var offset = 0, result: [Page] = []
        func integer(_ start: Int, _ width: Int) -> UInt64 {
            (0..<width).reduce(0) { $0 | UInt64(data[start + $1]) << ($1 * 8) }
        }
        while offset < data.count {
            XCTAssertGreaterThanOrEqual(data.count - offset, 28)
            guard data.count - offset >= 28 else { throw TelegramRecordedVoiceError.invalidRecording }
            XCTAssertEqual(data[offset..<offset + 4], Data("OggS".utf8))
            let segments = Int(data[offset + 26]), body = offset + 27 + segments
            guard body <= data.count else { throw TelegramRecordedVoiceError.invalidRecording }
            let size = data[offset + 27..<body].reduce(0) { $0 + Int($1) }, end = body + size
            guard end <= data.count else { throw TelegramRecordedVoiceError.invalidRecording }
            var page = Data(data[offset..<end]); page.replaceSubrange(22..<26, with: [0, 0, 0, 0])
            XCTAssertEqual(crc(page), UInt32(integer(offset + 22, 4)))
            result.append(Page(start: offset, end: end, flags: data[offset + 5], granule: integer(offset + 6, 8),
                serial: UInt32(integer(offset + 14, 4)), sequence: UInt32(integer(offset + 18, 4)), packet: Data(data[body..<end])))
            offset = end
        }
        return result
    }

    private func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        for byte in data {
            value ^= UInt32(byte) << 24
            for _ in 0..<8 { value = (value & 0x8000_0000 != 0 ? 0x04c1_1db7 : 0) ^ (value &<< 1) }
        }
        return value
    }

    private func repairCRC(_ data: inout Data, start: Int, end: Int) {
        data.replaceSubrange(start + 22..<start + 26, with: [0, 0, 0, 0])
        let value = crc(Data(data[start..<end]))
        data.replaceSubrange(start + 22..<start + 26, with: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func nativeDecode(pages: [Page], skip: Int, count: Int) throws -> [Int16] {
        var status: Int32 = 0
        let decoder = try XCTUnwrap(opus_decoder_create(48_000, 1, &status))
        defer { opus_decoder_destroy(decoder) }
        XCTAssertEqual(status, 0)
        var all: [Int16] = []
        for page in pages.dropFirst(2) {
            var frame = [Int16](repeating: 0, count: 960)
            let samples = page.packet.withUnsafeBytes { packet in
                frame.withUnsafeMutableBufferPointer { output in
                    opus_decode(decoder, packet.bindMemory(to: UInt8.self).baseAddress, Int32(packet.count), output.baseAddress!, 960, 0)
                }
            }
            XCTAssertEqual(samples, 960)
            all += frame
        }
        guard all.count >= skip + count else { throw TelegramRecordedVoiceError.invalidRecording }
        return Array(all[skip..<skip + count])
    }
}
