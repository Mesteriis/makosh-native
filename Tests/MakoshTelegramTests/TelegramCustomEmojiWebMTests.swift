import XCTest
import Foundation
@testable import MakoshTelegram

final class TelegramCustomEmojiWebMTests: XCTestCase {
    private let color0 = Data(base64Encoded: "gkmDQgAAMAAWADgkHBgAAAAgAAAgy////D97/TDCU///NXRZudL+9/////BlPxMmbgWvBjgA")!
    private let alpha0 = Data(base64Encoded: "gkmDQgAAMAAWADgkHBgAAAAgAAAgy5o//3UU4AA=")!
    private let color1 = Data(base64Encoded: "hgBAkvABAAAACAAAAbN///6wh/rJQ0////90b36mkvnSN+pln////9ggO/6XUe3qHQA=")!
    private let alpha1 = Data(base64Encoded: "hgBAkvABAAAACAAAAbN///9t8/9+7gAA")!

    // Catches treating BlockAdditional alpha as an unrelated track, losing
    // packet order, or applying nanosecond DefaultDuration as TimestampScale.
    func testActualWebMRetainsSeparateAlphaPacketsAndExactTimeline() throws {
        let bytes = Data(base64Encoded: "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAKVEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHWTbuMU6uEElTDZ1OsggE2TbuMU6uEHFO7a1OsggJ/7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxMYXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAj0AAAAAAABZUrmvbrgEAAAAAAABS14EBc8WILZqr+Z+uSE2cgQAitZyDdW5kiIEAhoVWX1ZQOYOBASPjg4QdzWUA4JSwgQS6gQKagQJTwIEBVbCEVbmBAVXugQHsAQAAAAAAAAIAABJUw2f2c3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2My4xLjEwMnNz0WPAi2PFiC2aq/mfrkhNZ8icRaOHRU5DT0RFUkSHj0xhdmMgbGlidnB4LXZwOWfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDEuMDAwMDAwMDAwAB9DtnVAyOeBAKDjobqBAAAAgkmDQgAAMAAWADgkHBgAAAAgAAAgy////D97/TDCU///NXRZudL+9/////BlPxMmbgWvBjgAdaGkpqLugQGlnYJJg0IAADAAFgA4JBwYAAAAIAAAIMuaP/91FOAAoN6htoEB9ACGAECS8AEAAAAIAAABs3///rCH+slDT////3RvfqaS+dI36mWf////2CA7/pdR7eodAHWhn6ad7oEBpZiGAECS8AEAAAAIAAABs3///23z/37uAAD7gv4MHFO7a5G7j7OBALeK94EB8YIBsfCBAw==")!
        let movie = try XCTUnwrap(try? TelegramCustomEmojiWebM(bytes: bytes))
        XCTAssertEqual(movie.width, 4); XCTAssertEqual(movie.height, 2)
        XCTAssertTrue(movie.hasAlpha)
        XCTAssertEqual(movie.defaultDuration, 0.5)
        XCTAssertEqual(movie.declaredDuration, 1)
        XCTAssertEqual(movie.packets.map(\.time), [0, 0.5])
        XCTAssertEqual(movie.packets.map(\.color), [color0, color1])
        XCTAssertEqual(movie.packets.map(\.alpha), [alpha0, alpha1])
    }

    // Catches rejecting common finite files with an unknown Segment size or
    // assuming every VP9 sticker has an alpha plane.
    func testUnknownSegmentAndSimpleBlockColorOnlyProfileIsAccepted() throws {
        let bytes = header() + Data([0x18, 0x53, 0x80, 0x67, 0xff]) + info() + tracks(alpha: false)
            + element(0x1f43b675, uint(0xe7, 0) + element(0xa3, block(color0, time: 0)))
        let movie = try XCTUnwrap(try? TelegramCustomEmojiWebM(bytes: bytes))
        XCTAssertFalse(movie.hasAlpha)
        XCTAssertEqual(movie.packets.count, 1)
        XCTAssertEqual(movie.packets.first?.color, color0)
        XCTAssertNil(movie.packets.first?.alpha)
    }

    // Catches reading beyond EBML element bounds or laundering an unsupported
    // encrypted/laced/multi-track stream into a single valid emoji.
    func testTruncationAmbiguousTracksAndUnsupportedLacingFailClosed() throws {
        let valid = movie(alpha: false, blocks: [element(0xa3, block(color0, time: 0))])
        for length in [0, 1, 4, valid.count - 1] {
            XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: Data(valid.prefix(length))))
        }
        let duplicate = header() + element(0x18538067, info() + tracks(alpha: false) + tracks(alpha: false)
            + element(0x1f43b675, uint(0xe7, 0) + element(0xa3, block(color0, time: 0))))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: duplicate))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: movie(alpha: false,
            blocks: [element(0xa3, block(color0, time: 0, flags: 0x82))])))
        let wrongCodec = header() + element(0x18538067, info() + tracks(alpha: false, codec: "V_VP8")
            + element(0x1f43b675, uint(0xe7, 0) + element(0xa3, block(color0, time: 0))))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: wrongCodec))
    }

    // Catches a partially transparent movie falling back to opaque frames when
    // its alpha packet is absent or repeated, and accepting reordered time.
    func testAlphaCardinalityAndTimelineAreValidatedBeforeNativeDecoding() throws {
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: movie(alpha: true,
            blocks: [element(0xa3, block(color0, time: 0))])))
        let repeatedAlpha = element(0xa0, element(0xa1, block(color0, time: 0))
            + element(0x75a1, more(alpha0) + more(alpha0)))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: movie(alpha: true, blocks: [repeatedAlpha])))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: movie(alpha: false,
            blocks: [element(0xa3, block(color0, time: 500)), element(0xa3, block(color1, time: 0))])))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: movie(alpha: false, width: 513,
            blocks: [element(0xa3, block(color0, time: 0))])))
        XCTAssertThrowsError(try TelegramCustomEmojiWebM(bytes: movie(alpha: false, duration: 10,
            blocks: [element(0xa3, block(color0, time: 0))])))
    }

    private func movie(alpha: Bool, width: UInt64 = 4, duration: Double = 1, blocks: [Data]) -> Data {
        header() + element(0x18538067, info(duration: duration) + tracks(alpha: alpha, width: width)
            + element(0x1f43b675, uint(0xe7, 0) + blocks.reduce(Data(), +)))
    }
    private func header() -> Data {
        element(0x1a45dfa3, uint(0x4286, 1) + uint(0x42f7, 1) + uint(0x42f2, 4)
            + uint(0x42f3, 8) + element(0x4282, Data("webm".utf8)) + uint(0x4287, 4) + uint(0x4285, 2))
    }
    private func info(duration: Double = 1) -> Data {
        var bits = (duration * 1000).bitPattern.bigEndian
        return element(0x1549a966, uint(0x2ad7b1, 1_000_000)
            + element(0x4489, withUnsafeBytes(of: &bits) { Data($0) }))
    }
    private func tracks(alpha: Bool, width: UInt64 = 4, codec: String = "V_VP9") -> Data {
        let video = element(0xe0, uint(0xb0, width) + uint(0xba, 2) + uint(0x53c0, alpha ? 1 : 0))
        let entry = uint(0xd7, 1) + uint(0x73c5, 1) + uint(0x83, 1) + uint(0x23e383, 500_000_000)
            + element(0x86, Data(codec.utf8)) + video
        return element(0x1654ae6b, element(0xae, entry))
    }
    private func block(_ packet: Data, time: Int16, flags: UInt8 = 0x80) -> Data {
        var bits = time.bigEndian
        return Data([0x81]) + withUnsafeBytes(of: &bits) { Data($0) } + Data([flags]) + packet
    }
    private func more(_ alpha: Data) -> Data { element(0xa6, uint(0xee, 1) + element(0xa5, alpha)) }
    private func uint(_ id: UInt32, _ number: UInt64) -> Data {
        var bytes = withUnsafeBytes(of: number.bigEndian) { Data($0) }
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        return element(id, bytes)
    }
    private func element(_ id: UInt32, _ payload: Data) -> Data {
        var bytes = withUnsafeBytes(of: id.bigEndian) { Data($0) }
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        let count = payload.count
        if count < 127 { bytes.append(UInt8(count) | 0x80) }
        else { bytes.append(UInt8(count >> 8) | 0x40); bytes.append(UInt8(count & 0xff)) }
        return bytes + payload
    }
}
