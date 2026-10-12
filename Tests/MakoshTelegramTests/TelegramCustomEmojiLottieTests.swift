import XCTest
import Foundation
import MakoshCustomEmojiControl

final class TelegramCustomEmojiLottieTests: XCTestCase {
    // Hand-authored synthetic vector animation: red then green on the left,
    // transparent right half. No Telegram account, downloaded asset or codec
    // is used to compute the expected pixels.
    private let vector = Data(#"{"v":"5.5.7","fr":2,"ip":0,"op":2,"w":4,"h":2,"nm":"Synthetic custom emoji","ddd":0,"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"half canvas","sr":1,"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,"shapes":[{"ty":"rc","d":1,"s":{"a":0,"k":[2,2]},"p":{"a":0,"k":[1,1]},"r":{"a":0,"k":0},"nm":"rectangle"},{"ty":"fl","c":{"a":1,"k":[{"t":0,"s":[1,0,0,1],"h":1},{"t":1,"s":[0,1,0,1],"h":1}]},"o":{"a":0,"k":100},"r":1,"nm":"animated color"}],"ip":0,"op":2,"st":0,"bm":0}]}"#.utf8)

    // Catches a placeholder/static renderer, wrong channel ordering or alpha
    // being flattened before the frame reaches the native Swift boundary.
    func testNativeLottieRendersDistinctFramesWithPremultipliedTransparency() throws {
        var info = MakoshEmojiLottieInfo()
        let raw = vector.withUnsafeBytes { bytes in
            makosh_emoji_lottie_create(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &info)
        }
        guard let animation = raw else { XCTFail("Reviewed native vector decoder must construct an animation"); return }
        defer { makosh_emoji_lottie_destroy(animation) }
        XCTAssertEqual(info.width, 4); XCTAssertEqual(info.height, 2)
        XCTAssertEqual(info.frame_count, 2); XCTAssertEqual(info.frame_rate, 2)
        var first = Data(repeating: 0x7f, count: 32), second = first
        let a = first.withUnsafeMutableBytes { bytes in
            makosh_emoji_lottie_render(animation, 0, 4, 2, bytes.bindMemory(to: UInt8.self).baseAddress, 16, bytes.count)
        }
        let b = second.withUnsafeMutableBytes { bytes in
            makosh_emoji_lottie_render(animation, 1, 4, 2, bytes.bindMemory(to: UInt8.self).baseAddress, 16, bytes.count)
        }
        XCTAssertEqual(a, 0); XCTAssertEqual(b, 0)
        XCTAssertEqual(Array(first[0..<4]), [0, 0, 255, 255])
        XCTAssertEqual(Array(second[0..<4]), [0, 255, 0, 255])
        XCTAssertEqual(Array(first[12..<16]), [0, 0, 0, 0])
        XCTAssertEqual(Array(second[12..<16]), [0, 0, 0, 0])
    }

    // Catches invalid output shape, frame index or buffer capacity causing
    // writes to memory which the caller has not granted to the decoder.
    func testNativeLottieRejectsInvalidRenderWithoutTouchingCallerBuffer() throws {
        var info = MakoshEmojiLottieInfo()
        let raw = vector.withUnsafeBytes { bytes in
            makosh_emoji_lottie_create(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &info)
        }
        guard let animation = raw else { XCTFail("Valid fixture must construct before buffer-boundary assertions"); return }
        defer { makosh_emoji_lottie_destroy(animation) }
        for (frame, width, height, stride, capacity): (UInt32, UInt32, UInt32, Int, Int) in [
            (2, 4, 2, 16, 32), (0, 0, 2, 16, 32), (0, 513, 2, 2052, 32),
            (0, 4, 2, 15, 32), (0, 4, 2, 16, 31)] {
            var output = Data(repeating: 0x7f, count: 32)
            let code = output.withUnsafeMutableBytes { bytes in
                makosh_emoji_lottie_render(animation, frame, width, height,
                    bytes.bindMemory(to: UInt8.self).baseAddress, stride, capacity)
            }
            XCTAssertNotEqual(code, 0); XCTAssertEqual(output, Data(repeating: 0x7f, count: 32))
        }
    }
    // Catches invalid or oversized source bytes being accepted before the
    // parser boundary; a malformed vector cannot silently render blank.
    func testNativeLottieRejectsMalformedAndOversizedInput() {
        for bytes in [Data(), Data("{}".utf8), Data("not json".utf8), Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)] {
            var info = MakoshEmojiLottieInfo()
            let animation = bytes.withUnsafeBytes { raw in
                makosh_emoji_lottie_create(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &info)
            }
            XCTAssertNil(animation)
            if let animation { makosh_emoji_lottie_destroy(animation) }
        }
    }
}
