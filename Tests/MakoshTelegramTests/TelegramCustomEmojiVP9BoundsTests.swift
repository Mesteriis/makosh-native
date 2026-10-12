import XCTest
import Foundation
import MakoshCustomEmojiControl

final class TelegramCustomEmojiVP9BoundsTests: XCTestCase {
    // Characterizes the pinned codec's actual pre-allocation dimension guard:
    // an IVF/VP9 keyframe independently reported as514×2 cannot evade a4×2 canvas.
    func testOversizeBitstreamNeverPublishesPixelsAndInvalidatesDecoder() throws {
        let decoder = try XCTUnwrap(makosh_emoji_vp9_create(4, 2, 0))
        defer { makosh_emoji_vp9_destroy(decoder) }
        let oversized = Data(base64Encoded: "gkmDQgAgEAAWADgkHBgAEABQfzfR17R0HX0gAAAAAA4EA8sWPqiSBAvXGArAAAQDyxY+qJIEC9cYCtIA")!
        let valid = Data(base64Encoded: "gkmDQgAAMAAWADgkHBgAAAAgAAAgy////D97/TDCU///NXRZudL+9/////BlPxMmbgWvBjgA")!
        var output = Data(repeating: 0xa5, count: 32)
        for packet in [oversized, valid] {
            let result = packet.withUnsafeBytes { bytes in
                output.withUnsafeMutableBytes { pixels in
                    makosh_emoji_vp9_decode(decoder, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                        nil, 0, pixels.bindMemory(to: UInt8.self).baseAddress, 16, 32)
                }
            }
            XCTAssertLessThan(result, 0)
            XCTAssertEqual(output, Data(repeating: 0xa5, count: 32))
        }
    }
}
