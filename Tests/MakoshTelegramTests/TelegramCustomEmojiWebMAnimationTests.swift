import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramCustomEmojiWebMAnimationTests: XCTestCase {
    // The fixture starts from literal BT.601 YUVA420p planes, exact alpha128,
    // and original RGBA primary-color expectations. FFmpeg is encoder-only.
    private let bytes = Data(base64Encoded: "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAKVEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHWTbuMU6uEElTDZ1OsggE2TbuMU6uEHFO7a1OsggJ/7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxMYXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAj0AAAAAAABZUrmvbrgEAAAAAAABS14EBc8WILZqr+Z+uSE2cgQAitZyDdW5kiIEAhoVWX1ZQOYOBASPjg4QdzWUA4JSwgQS6gQKagQJTwIEBVbCEVbmBAVXugQHsAQAAAAAAAAIAABJUw2f2c3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2My4xLjEwMnNz0WPAi2PFiC2aq/mfrkhNZ8icRaOHRU5DT0RFUkSHj0xhdmMgbGlidnB4LXZwOWfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDEuMDAwMDAwMDAwAB9DtnVAyOeBAKDjobqBAAAAgkmDQgAAMAAWADgkHBgAAAAgAAAgy////D97/TDCU///NXRZudL+9/////BlPxMmbgWvBjgAdaGkpqLugQGlnYJJg0IAADAAFgA4JBwYAAAAIAAAIMuaP/91FOAAoN6htoEB9ACGAECS8AEAAAAIAAABs3///rCH+slDT////3RvfqaS+dI36mWf////2CA7/pdR7eodAHWhn6ad7oEBpZiGAECS8AEAAAAIAAABs3///23z/37uAAD7gv4MHFO7a5G7j7OBALeK94EB8YIBsfCBAw==")!

    // Catches missing WebM integration, alpha flattening, and reuse of advanced
    // VP9 references when a loop or backwards frame request returns to start.
    func testActualWebMAlphaFramesAndBackwardRequestsPreserveSourcePixels() async throws {
        guard let decoder = try? TelegramCustomEmojiAnimationDecoder(bytes: bytes, format: .webM) else {
            XCTFail("Valid bounded WebM must construct a real decoder"); return
        }
        XCTAssertEqual(decoder.info.width, 4); XCTAssertEqual(decoder.info.height, 2)
        XCTAssertEqual(decoder.info.frameDurations, [0.5, 0.5])
        for index in [0, 1, 0, 1] {
            let frame = try await decoder.frame(index: index, width: 4, height: 2)
            XCTAssertEqual(frame.pixels.count, 32)
            if index == 0 {
                assertPixel(frame.pixels, offset: 0, expected: [0, 0, 255, 255])
                assertPixel(frame.pixels, offset: 8, expected: [0, 0, 0, 0])
            } else {
                assertPixel(frame.pixels, offset: 0, expected: [0, 255, 0, 255])
                assertPixel(frame.pixels, offset: 8, expected: [128, 0, 0, 128])
            }
        }
        let fitted = try await decoder.frame(index: 0, width: 8, height: 8)
        XCTAssertEqual(fitted.pixels.count, 256)
        XCTAssertEqual(fitted.pixels[3], 0)
        XCTAssertEqual(fitted.pixels[(7 * 8) * 4 + 3], 0)
        assertPixel(fitted.pixels, offset: (3 * 8 + 1) * 4, expected: [0, 0, 255, 255])
    }

    private func assertPixel(_ data: Data, offset: Int, expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        guard data.count >= offset + 4 else { XCTFail("Incomplete frame", file: file, line: line); return }
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(data[offset + channel]) - Int(expected[channel])), 2, file: file, line: line)
        }
        XCTAssertEqual(data[offset + 3], expected[3], file: file, line: line)
    }
}
