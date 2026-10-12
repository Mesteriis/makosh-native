import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramCustomEmojiWebMProfileTests: XCTestCase {
    private let packet = Data(base64Encoded: "gkmDQgAAMAAWADgkHBgAAAAgAAAgy////D97/TDCU///NXRZudL+9/////BlPxMmbgWvBjgA")!
    // Catches treating a track's unsupported BlockAddition mapping as harmless metadata.
    func testUnsupportedTrackAdditionMappingCannotAcquireAlphaAuthority() throws {
        XCTAssertNotNil(try? TelegramCustomEmojiWebM(bytes: movie()))
        let mapping = element(0x41e4, uint(0x41f0, 1) + uint(0x41e7, 0)
            + element(0x41a4, Data("unsupported-alpha-format".utf8)))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: movie(trackExtension: mapping)))
    }
    // Catches rendering stereo-packed source frames as an ordinary flat emoji.
    func testNonzeroStereoLayoutFallsBackWhileExplicitMonoRemainsSupported() throws {
        XCTAssertNotNil(try? TelegramCustomEmojiWebM(bytes: movie(videoExtension: uint(0x53b8, 0))))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: movie(videoExtension: uint(0x53b8, 1))))
    }
    // Catches ignoring a non-rectangular projection and publishing geometrically wrong pixels.
    func testUnsupportedProjectionCannotBeSkippedAsFiniteVideoMetadata() throws {
        XCTAssertNotNil(try? TelegramCustomEmojiWebM(bytes: movie()))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: movie(videoExtension: element(0x7670, uint(0x7671, 1)))))
    }
    private func movie(trackExtension: Data = Data(), videoExtension: Data = Data()) -> Data {
        let header = element(0x1a45dfa3, uint(0x4286, 1) + uint(0x42f7, 1) + uint(0x42f2, 4)
            + uint(0x42f3, 8) + element(0x4282, Data("webm".utf8)) + uint(0x4287, 4) + uint(0x4285, 2))
        let info = element(0x1549a966, uint(0x2ad7b1, 1_000_000))
        let video = element(0xe0, uint(0xb0, 4) + uint(0xba, 2) + videoExtension)
        let track = uint(0xd7, 1) + uint(0x83, 1) + element(0x86, Data("V_VP9".utf8)) + video + trackExtension
        let cluster = element(0x1f43b675, uint(0xe7, 0) + element(0xa3, Data([0x81, 0, 0, 0x80]) + packet))
        return header + element(0x18538067, info + element(0x1654ae6b, element(0xae, track)) + cluster)
    }
    private func uint(_ id: UInt32, _ value: UInt64) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        return element(id, bytes)
    }
    private func element(_ id: UInt32, _ payload: Data) -> Data {
        var bytes = withUnsafeBytes(of: id.bigEndian) { Data($0) }
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        if payload.count < 127 { bytes.append(UInt8(payload.count) | 0x80) }
        else { bytes.append(UInt8(payload.count >> 8) | 0x40); bytes.append(UInt8(payload.count & 0xff)) }
        return bytes + payload
    }
}
