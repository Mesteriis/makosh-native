import XCTest
import Foundation
import MakoshCustomEmojiControl

final class TelegramCustomEmojiVP9Tests: XCTestCase {
    // Color and alpha BlockAdditionalID=1 packets extracted from our literal
    // 4×2 RGBA fixture (WebM SHA256 c453d784f841ef2ecc9294cd6f24f7e6a9dccc1640249ac5762c77b20c7ad59a).
    // Literal YUVA planes avoid RGB-to-YUV alpha rounding. ffmpeg is a fixture
    // encoder only; expectations retain the original RGB/alpha literals.
    private let color0 = Data(base64Encoded: "gkmDQgAAMAAWADgkHBgAAAAgAAAgy////D97/TDCU///NXRZudL+9/////BlPxMmbgWvBjgA")!
    private let alpha0 = Data(base64Encoded: "gkmDQgAAMAAWADgkHBgAAAAgAAAgy5o//3UU4AA=")!
    private let color1 = Data(base64Encoded: "hgBAkvABAAAACAAAAbN///6wh/rJQ0////90b36mkvnSN+pln////9ggO/6XUe3qHQA=")!
    private let alpha1 = Data(base64Encoded: "hgBAkvABAAAACAAAAbN///9t8/9+7gAA")!

    // Catches a placeholder/native color-only decoder or flattened/wrong alpha.
    func testNativeVP9DecodesBothFramesWithIndependentAlphaPackets() throws {
        let decoder = try XCTUnwrap(makosh_emoji_vp9_create(4, 2, 1))
        defer { makosh_emoji_vp9_destroy(decoder) }
        var pixels = Data(repeating: 0x7f, count: 32)
        let first = decode(decoder, color0, alpha0, into: &pixels)
        XCTAssertEqual(first, 0)
        guard first == 0 else { return }
        assertPixel(pixels, offset: 0, expected: [0, 0, 255, 255])
        assertPixel(pixels, offset: 8, expected: [0, 0, 0, 0])
        assertPixel(pixels, offset: 16, expected: [0, 0, 255, 255])
        let second = decode(decoder, color1, alpha1, into: &pixels)
        XCTAssertEqual(second, 0)
        guard second == 0 else { return }
        assertPixel(pixels, offset: 0, expected: [0, 255, 0, 255])
        assertPixel(pixels, offset: 8, expected: [128, 0, 0, 128])
        assertPixel(pixels, offset: 24, expected: [128, 0, 0, 128])
    }

    // Catches a capacity/stride failure writing partial output or poisoning a
    // decoder before a packet was consumed.
    func testInvalidCallerBufferIsUntouchedAndValidFrameCanStillDecode() throws {
        let decoder = try XCTUnwrap(makosh_emoji_vp9_create(4, 2, 1))
        defer { makosh_emoji_vp9_destroy(decoder) }
        var pixels = Data(repeating: 0x7f, count: 32)
        for (stride, capacity) in [(15, 32), (16, 31)] {
            XCTAssertLessThan(decode(decoder, color0, alpha0, into: &pixels, stride: stride, capacity: capacity), 0)
            XCTAssertEqual(pixels, Data(repeating: 0x7f, count: 32))
        }
        let status = decode(decoder, color0, alpha0, into: &pixels)
        XCTAssertEqual(status, 0)
        guard status == 0 else { return }
        assertPixel(pixels, offset: 0, expected: [0, 0, 255, 255])
    }

    // Characterizes the native accepted/no-frame status: both invisible
    // keyframes must advance references without publishing caller pixels.
    func testInvisiblePacketsAdvanceBothContextsWithoutWritingOutput() throws {
        let decoder = try XCTUnwrap(makosh_emoji_vp9_create(4, 2, 1))
        defer { makosh_emoji_vp9_destroy(decoder) }
        var hiddenColor = color0, hiddenAlpha = alpha0
        // VP9 profile0 keyframe: bit1 is show_frame (native header parser).
        hiddenColor[0] &= 0xfd; hiddenAlpha[0] &= 0xfd
        var pixels = Data(repeating: 0x7f, count: 32)
        let invisible = decode(decoder, hiddenColor, hiddenAlpha, into: &pixels)
        XCTAssertEqual(invisible, 1)
        XCTAssertEqual(pixels, Data(repeating: 0x7f, count: 32))
        guard invisible == 1 else { return }
        let visible = decode(decoder, color1, alpha1, into: &pixels)
        XCTAssertEqual(visible, 0)
        guard visible == 0 else { return }
        assertPixel(pixels, offset: 0, expected: [0, 255, 0, 255])
        assertPixel(pixels, offset: 8, expected: [128, 0, 0, 128])
    }

    // Catches reuse of a color context after corrupt/missing alpha changed only
    // one native decoder, and unchecked canvas/packet allocations.
    func testCorruptPacketInvalidatesDecoderWithoutPublishingPixels() throws {
        for (width, height, alpha): (UInt32, UInt32, Int32) in [(0, 2, 1), (4, 0, 1), (513, 2, 1), (4, 513, 1), (4, 2, 2)] {
            let invalid = makosh_emoji_vp9_create(width, height, alpha)
            XCTAssertNil(invalid)
            if let invalid { makosh_emoji_vp9_destroy(invalid) }
        }
        let decoder = try XCTUnwrap(makosh_emoji_vp9_create(4, 2, 1))
        defer { makosh_emoji_vp9_destroy(decoder) }
        var pixels = Data(repeating: 0x7f, count: 32)
        XCTAssertLessThan(decode(decoder, color0, Data([0]), into: &pixels), 0)
        XCTAssertEqual(pixels, Data(repeating: 0x7f, count: 32))
        XCTAssertLessThan(decode(decoder, color0, alpha0, into: &pixels), 0)
        XCTAssertEqual(pixels, Data(repeating: 0x7f, count: 32))
    }

    private func decode(_ decoder: OpaquePointer, _ color: Data, _ alpha: Data,
        into output: inout Data, stride: Int = 16, capacity: Int = 32) -> Int32 {
        color.withUnsafeBytes { c in
            alpha.withUnsafeBytes { a in
                output.withUnsafeMutableBytes { pixels in
                    makosh_emoji_vp9_decode(decoder, c.bindMemory(to: UInt8.self).baseAddress, c.count,
                        a.bindMemory(to: UInt8.self).baseAddress, a.count,
                        pixels.bindMemory(to: UInt8.self).baseAddress, stride, capacity)
                }
            }
        }
    }

    private func assertPixel(_ bytes: Data, offset: Int, expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        guard bytes.count >= offset + 4 else { XCTFail("Incomplete frame", file: file, line: line); return }
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(bytes[offset + channel]) - Int(expected[channel])), 2, file: file, line: line)
        }
        XCTAssertEqual(bytes[offset + 3], expected[3], file: file, line: line)
    }
}
