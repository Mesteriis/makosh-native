import XCTest
import Foundation
import ImageIO
import MakoshJPEGControl
import MakoshJPEGFaultFixture

final class TelegramJPEGControlTests: XCTestCase {
    // Catches stale destination ownership after a successful growth followed by OOM.
    func testOutputAllocationFailuresReleaseCurrentBufferAndClearOutputs() {
        for failure: UInt32 in [0, 1, 2, 3] {
            XCTAssertEqual(makosh_jpeg_fault_case(failure), 0, "allocation \(failure): double-free/leak/invalid return")
        }
    }
    // Catches channel order/component-count mistakes without assuming a host ColorSync profile.
    func testRGBXInputKeepsRedGreenBlueChannels() throws {
        var input = Data(count: 96 * 32 * 4)
        for y in 0..<32 { for x in 0..<96 { input[(y * 96 + x) * 4 + x / 32] = 255 } }
        var output: UnsafeMutablePointer<UInt8>?, length = 0
        let accepted = input.withUnsafeBytes { buffer in
            makosh_jpeg_encode_rgbx75(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, 96, 32, 384, &output, &length)
        }
        XCTAssertEqual(accepted, 1)
        let bytes = try XCTUnwrap(output); defer { free(bytes) }
        let data = Data(bytes: bytes, count: length)
        let decoder = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        XCTAssertEqual(image.width, 96); XCTAssertEqual(image.height, 32)
        XCTAssertEqual(image.bitsPerPixel, 32); XCTAssertEqual(image.alphaInfo, .noneSkipLast)
        let raw = try XCTUnwrap(image.dataProvider?.data) as Data
        for (channel, x) in [16, 48, 80].enumerated() { for component in 0..<3 {
            let value = raw[16 * image.bytesPerRow + x * 4 + component]
            if channel == component { XCTAssertGreaterThanOrEqual(value, 245) }
            else { XCTAssertLessThanOrEqual(value, 10) }
        } }
    }

    // Catches short buffers, invalid dimensions/strides, overflow and stale output ownership on failure.
    func testInvalidShapesRefuseAndClearOutput() {
        for (width, height, stride, count) in [(UInt32(0), UInt32(1), 4, 4), (1, 0, 4, 4),
            (2561, 1, 10244, 4), (1, 2561, 4, 4), (2, 1, 4, 4), (1, 2, 4, 7), (1, 2, Int.max, 4)] {
            var output = UnsafeMutablePointer<UInt8>(bitPattern: 1), length = 999
            let input = Data(repeating: 255, count: 16)
            let accepted = input.withUnsafeBytes { buffer in
                makosh_jpeg_encode_rgbx75(buffer.bindMemory(to: UInt8.self).baseAddress, count,
                    width, height, stride, &output, &length)
            }
            XCTAssertEqual(accepted, 0); XCTAssertNil(output); XCTAssertEqual(length, 0)
        }
        var output = UnsafeMutablePointer<UInt8>(bitPattern: 1), length = 999
        XCTAssertEqual(makosh_jpeg_encode_rgbx75(nil, 4, 1, 1, 4, &output, &length), 0)
        XCTAssertNil(output); XCTAssertEqual(length, 0)
        XCTAssertEqual(makosh_jpeg_encode_rgbx75(nil, 0, 0, 0, 0, nil, nil), 0)
    }
}
