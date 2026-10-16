import CoreMedia
import CoreVideo
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppCallMediaTests: XCTestCase {
  func testPCMFramesKeepOnlyBoundedNewestCompleteInput() throws {
    var framer = WhatsAppPCMFrames()
    framer.append(Array(repeating: Int16(1), count: 960 * 10 + 40))
    let first = framer.take()
    XCTAssertEqual(first.count, 3)
    XCTAssertTrue(first.allSatisfy { $0.count == 960 })
    XCTAssertTrue(framer.take().isEmpty)
    framer.append(Array(repeating: Int16(2), count: 920))
    let next = framer.take()
    XCTAssertEqual(next.count, 1)
    XCTAssertEqual(Array(next[0].prefix(40)), Array(repeating: 1, count: 40))
    XCTAssertEqual(next[0].last, 2)
  }
  func testH264RoundTripUsesNativeCodecWithoutOpeningDevices() async throws {
    let decoded = expectation(description: "Decoded generated frame")
    let codec = WhatsAppH264Codec()
    codec.onDecoded = { image in
      XCTAssertFalse(Thread.isMainThread)
      XCTAssertEqual(image.width, 64)
      XCTAssertEqual(image.height, 64)
      decoded.fulfill()
    }
    codec.onEncoded = { data in codec.decode(data) }
    var buffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        nil, 64, 64, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let frame = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    if let bytes = CVPixelBufferGetBaseAddress(frame) {
      memset(bytes, 80, CVPixelBufferGetBytesPerRow(frame) * 64)
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    codec.encode(frame, time: .zero)
    await fulfillment(of: [decoded], timeout: 5)
    await codec.stop()
  }
}

extension WhatsAppCallMediaTests {
  func testDecodeBurstKeepsBoundedPendingFramesAndStopClearsThem() async throws {
    let queue = DispatchQueue(label: "qa.whatsapp.blocked.codec")
    let gate = DispatchSemaphore(value: 0)
    queue.async { gate.wait() }
    let codec = WhatsAppH264Codec(queue: queue)
    for _ in 0..<1000 { codec.decode(Data([0, 0, 0, 1, 0x65, 1, 2, 3])) }
    XCTAssertLessThanOrEqual(codec.pendingDecodeCount, 2)
    gate.signal()
    await codec.stop()
    XCTAssertEqual(codec.pendingDecodeCount, 0)
  }
}
