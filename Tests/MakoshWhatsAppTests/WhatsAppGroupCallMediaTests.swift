import CoreGraphics
import XCTest

@testable import MakoshWhatsApp

private final class GroupDecoder: WhatsAppParticipantDecoding, @unchecked Sendable {
  let lock = NSLock()
  var onDecoded: (@Sendable (CGImage) -> Void)?
  var values: [Data] = []
  var stopped = false
  func decode(_ data: Data, orientation: UInt8) { lock.withLock { values.append(data) } }
  func stop() async { lock.withLock { stopped = true } }
  func emit(_ image: CGImage) { onDecoded?(image) }
}
private final class DecoderList: @unchecked Sendable {
  let lock = NSLock()
  var values: [GroupDecoder] = []
  func make() -> any WhatsAppParticipantDecoding {
    let d = GroupDecoder()
    lock.withLock { values.append(d) }
    return d
  }
}
final class WhatsAppGroupCallMediaTests: XCTestCase {
  private func stream(_ n: Int, pid: UInt32 = 1) -> WhatsAppCallStreamID {
    .init(sender: "20\(n)@lid", device: "20\(n):2@lid", pid: pid)
  }
  private func roster(_ ids: [WhatsAppCallStreamID]) -> WhatsAppGroupCallSnapshot {
    .init(
      groupJID: "1@g.us", rosterRevision: 1,
      participants: ids.map {
        .init(jid: $0.sender, state: "connected", devices: [.init(jid: $0.device, pid: $0.pid)])
      })
  }
  private func output(_ ids: [WhatsAppCallStreamID], key: Bool = true) -> WhatsAppCallOutput {
    .init(
      audio: [], video: nil, keyframe: false, orientation: 0,
      videos: ids.map {
        .init(
          stream: $0, keyframe: key, orientation: 0,
          bytes: key
            ? [0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 1, 0, 0, 0, 1, 0x65, 1]
            : [0, 0, 0, 1, 0x41, 1])
      })
  }
  func testTwoParticipantsNeverShareDecoderOrLastFrame() async throws {
    let list = DecoderList()
    let m = WhatsAppGroupCallMedia(factory: { list.make() })
    let ids = [stream(1), stream(2)]
    try await m.setVisibleStreams(ids, callID: "c", epoch: 1)
    await m.receive(output(ids), callID: "c", epoch: 1, roster: roster(ids))
    XCTAssertEqual(list.values.count, 2)
    guard list.values.count == 2 else { return }
    XCTAssertFalse(list.values[0] === list.values[1])
    XCTAssertEqual(list.values[0].values.count, 1)
    XCTAssertEqual(list.values[1].values.count, 1)
    await m.stop()
  }
  func testPidMigrationAndDepartedStreamFlush() async throws {
    let list = DecoderList()
    let m = WhatsAppGroupCallMedia(factory: { list.make() })
    let old = stream(1)
    let next = stream(1, pid: 7)
    try await m.setVisibleStreams([old], callID: "c", epoch: 1)
    await m.receive(output([old]), callID: "c", epoch: 1, roster: roster([old]))
    try await m.setVisibleStreams([next], callID: "c", epoch: 1)
    await m.receive(output([old, next]), callID: "c", epoch: 1, roster: roster([next]))
    XCTAssertEqual(list.values.count, 2)
    XCTAssertEqual(list.values.first?.stopped, true)
    await m.receive(output([next]), callID: "c", epoch: 1, roster: roster([]))
    XCTAssertEqual(list.values.last?.stopped, true)
    let images = await m.images()
    XCTAssertTrue(images.isEmpty)
    await m.stop()
  }
  func testGroupFramesBoundedFairAndRequireKeyframeOnReturn() async throws {
    let list = DecoderList()
    let m = WhatsAppGroupCallMedia(factory: { list.make() })
    let ids = (0..<9).map { stream($0) }
    try await m.setVisibleStreams(ids, callID: "c", epoch: 1)
    for chunk in stride(from: 0, to: 9, by: 4) {
      await m.receive(
        output(Array(ids[chunk..<min(chunk + 4, 9)])), callID: "c", epoch: 1, roster: roster(ids))
    }
    XCTAssertEqual(list.values.count, 9)
    let receipt = await m.selection()
    try await m.setVisibleStreams(Array(ids.dropFirst()), callID: "c", epoch: 1)
    try await m.setVisibleStreams(ids, callID: "c", epoch: 1)
    await m.receive(
      output([ids[0]]), callID: "c", epoch: 1, roster: roster(ids),
      expectedVisibilityRevision: receipt.revision)
    await m.receive(output([ids[0]], key: false), callID: "c", epoch: 1, roster: roster(ids))
    XCTAssertEqual(list.values.count, 9)
    await m.receive(output([ids[0]]), callID: "c", epoch: 1, roster: roster(ids))
    XCTAssertEqual(list.values.count, 10)
    do {
      try await m.setVisibleStreams(ids + [stream(10)], callID: "c", epoch: 1)
      XCTFail("ten visible decoders")
    } catch {}
    await m.stop()
  }
  func testMalformedNALDimensionsAndJSONLimits() async throws {
    let list = DecoderList()
    let m = WhatsAppGroupCallMedia(factory: { list.make() })
    let id = stream(1)
    try await m.setVisibleStreams([id], callID: "c", epoch: 1)
    var bad = output([id])
    bad.videos[0].bytes = Array(repeating: 0, count: 256 * 1024 + 1)
    await m.receive(bad, callID: "c", epoch: 1, roster: roster([id]))
    bad.videos[0].bytes = [0, 0, 0, 1, 0xff]
    await m.receive(bad, callID: "c", epoch: 1, roster: roster([id]))
    XCTAssertTrue(list.values.isEmpty)
    XCTAssertFalse(WhatsAppH264Codec.validDimensions(width: 3840, height: 2160))
    XCTAssertTrue(WhatsAppH264Codec.validDimensions(width: 1920, height: 1080))
    XCTAssertTrue(WhatsAppH264Codec.validDimensions(width: 1080, height: 1920))
    XCTAssertFalse(WhatsAppH264Codec.validDimensions(width: 0, height: 1))
    let old = try JSONDecoder().decode(
      WhatsAppCallOutput.self,
      from: Data(#"{"audio":[],"video":null,"keyframe":false,"orientation":0}"#.utf8))
    XCTAssertTrue(old.videos.isEmpty)
    let many = output(Array(repeating: id, count: 5))
    XCTAssertThrowsError(
      try JSONDecoder().decode(WhatsAppCallOutput.self, from: JSONEncoder().encode(many)))
    await m.stop()
  }
  func testStopDrainsWithoutMainThreadWait() async throws {
    let list = DecoderList()
    let m = WhatsAppGroupCallMedia(factory: { list.make() })
    let ids = [stream(1)]
    try await m.setVisibleStreams(ids, callID: "c", epoch: 1)
    await m.receive(output(ids), callID: "c", epoch: 1, roster: roster(ids))
    await m.stop()
    await m.receive(output(ids), callID: "c", epoch: 1, roster: roster(ids))
    XCTAssertEqual(list.values.count, 1)
    XCTAssertEqual(list.values.first?.stopped, true)
    let images = await m.images()
    XCTAssertTrue(images.isEmpty)
  }
}
extension WhatsAppGroupCallMediaTests {
  func testLateDecodedCallbackCannotPublishAfterPageOrEpochChange() async throws {
    let list = DecoderList()
    let m = WhatsAppGroupCallMedia(factory: { list.make() })
    let id = stream(1)
    try await m.setVisibleStreams([id], callID: "c", epoch: 1)
    await m.receive(output([id]), callID: "c", epoch: 1, roster: roster([id]))
    let d = try XCTUnwrap(list.values.first)
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = try XCTUnwrap(
      CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try XCTUnwrap(ctx.makeImage())
    d.emit(image)
    for _ in 0..<100 {
      if !(await m.images()).isEmpty { break }
      await Task.yield()
    }
    let first = await m.images()
    XCTAssertEqual(first.map(\.stream), [id])
    try await m.setVisibleStreams([], callID: "c", epoch: 1)
    try await m.setVisibleStreams([id], callID: "c", epoch: 2)
    d.emit(image)
    await m.receive(output([id]), callID: "c", epoch: 1, roster: roster([id]))
    for _ in 0..<10 { await Task.yield() }
    let late = await m.images()
    XCTAssertTrue(late.isEmpty)
    XCTAssertEqual(list.values.count, 1)
    await m.stop()
  }
}
