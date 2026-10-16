import COpus
import Foundation

/// Independently authored framing for our one-packet/page, mono20ms recordings.
/// This deliberately rejects general Ogg imports, chaining and continued packets.
package enum VoiceOgg {
  package struct Recording {
    package let preSkip: Int
    package let sampleCount: Int
    package let packets: [Data]
  }

  package static let tags =
    Data("OpusTags".utf8) + Data([6, 0, 0, 0]) + Data("Makosh".utf8) + Data([0, 0, 0, 0])

  package static func head(preSkip: UInt16) -> Data {
    Data("OpusHead".utf8) + Data([1, 1]) + littleEndian(UInt64(preSkip), bytes: 2)
      + littleEndian(48_000, bytes: 4) + Data([0, 0, 0])
  }

  package static func page(
    packet: Data, serial: UInt32, sequence: UInt32, granule: UInt64, flags: UInt8
  ) -> Data {
    // Only called with bounded native packets or the two fixed headers.
    let segments = packet.count / 255 + 1
    var result =
      Data("OggS".utf8) + Data([0, flags]) + littleEndian(granule, bytes: 8)
      + littleEndian(UInt64(serial), bytes: 4) + littleEndian(UInt64(sequence), bytes: 4)
      + Data([0, 0, 0, 0, UInt8(segments)])
    result.append(contentsOf: [UInt8](repeating: 255, count: segments - 1))
    result.append(UInt8(packet.count % 255))
    result.append(packet)
    result.replaceSubrange(22..<26, with: littleEndian(UInt64(checksum(result)), bytes: 4))
    return result
  }

  package static func parseRecording(_ data: Data) throws -> Recording {
    try Task.checkCancellation()
    var cursor = 0
    var sequence = 0
    var serial: UInt64 = 0
    var skip = 0
    var end: UInt64 = 0
    var packets: [Data] = []
    while cursor < data.count {
      try Task.checkCancellation()
      guard sequence < 30_004 else { throw RecordedVoiceError.invalidRecording }
      let parsed = try readPage(data, at: cursor)
      guard parsed.sequence == sequence else { throw RecordedVoiceError.invalidRecording }
      if sequence == 0 {
        serial = parsed.serial
        guard parsed.packet.count == 19 else { throw RecordedVoiceError.invalidRecording }
        skip = Int(integer(parsed.packet, at: 10, bytes: 2))
        guard parsed.flags == 2, parsed.granule == 0, (1...960).contains(skip),
          parsed.packet == head(preSkip: UInt16(skip))
        else { throw RecordedVoiceError.invalidRecording }
      } else {
        guard parsed.serial == serial else { throw RecordedVoiceError.invalidRecording }
        if sequence == 1 {
          guard parsed.flags == 0, parsed.granule == 0, parsed.packet == tags else {
            throw RecordedVoiceError.invalidRecording
          }
        } else {
          let sampleCount = parsed.packet.withUnsafeBytes { packet in
            opus_packet_get_nb_samples(
              packet.bindMemory(to: UInt8.self).baseAddress!, Int32(packet.count), 48_000)
          }
          guard sampleCount == 960 else { throw RecordedVoiceError.invalidRecording }
          let last = parsed.end == data.count
          let decoded = UInt64((sequence - 1) * 960)
          if last {
            guard parsed.flags == 4, parsed.granule > decoded - 960, parsed.granule <= decoded,
              parsed.granule > skip,
              parsed.granule - UInt64(skip) <= RecordedVoiceCodec.maximumSamples
            else {
              throw RecordedVoiceError.invalidRecording
            }
            end = parsed.granule
          } else {
            guard parsed.flags == 0, parsed.granule == decoded else {
              throw RecordedVoiceError.invalidRecording
            }
          }
          packets.append(parsed.packet)
        }
      }
      sequence += 1
      cursor = parsed.end
    }
    guard !packets.isEmpty, end > skip else { throw RecordedVoiceError.invalidRecording }
    return Recording(preSkip: skip, sampleCount: Int(end) - skip, packets: packets)
  }

  private struct Page {
    let end: Int
    let flags: UInt8
    let granule: UInt64, serial: UInt64, sequence: UInt64
    let packet: Data
  }

  private static func readPage(_ data: Data, at start: Int) throws -> Page {
    guard data.count - start >= 28, data[start..<start + 4] == Data("OggS".utf8),
      data[start + 4] == 0
    else {
      throw RecordedVoiceError.invalidRecording
    }
    let segments = Int(data[start + 26])
    let body = start + 27 + segments
    guard (1...16).contains(segments), body <= data.count else {
      throw RecordedVoiceError.invalidRecording
    }
    let lacing = data[start + 27..<body]
    guard lacing.dropLast().allSatisfy({ $0 == 255 }), let final = lacing.last, final < 255 else {
      throw RecordedVoiceError.invalidRecording
    }
    let length = (segments - 1) * 255 + Int(final)
    let end = body + length
    guard (1...4_000).contains(length), end <= data.count else {
      throw RecordedVoiceError.invalidRecording
    }
    var checked = Data(data[start..<end])
    checked.replaceSubrange(22..<26, with: [0, 0, 0, 0])
    guard UInt64(checksum(checked)) == integer(data, at: start + 22, bytes: 4) else {
      throw RecordedVoiceError.invalidRecording
    }
    return Page(
      end: end, flags: data[start + 5], granule: integer(data, at: start + 6, bytes: 8),
      serial: integer(data, at: start + 14, bytes: 4),
      sequence: integer(data, at: start + 18, bytes: 4),
      packet: Data(data[body..<end]))
  }

  private static func integer(_ data: Data, at start: Int, bytes: Int) -> UInt64 {
    (0..<bytes).reduce(0) { $0 | UInt64(data[start + $1]) << ($1 * 8) }
  }

  private static func littleEndian(_ value: UInt64, bytes: Int) -> Data {
    Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }

  private static let crcTable: [UInt32] = (0..<256).map { byte in
    var value = UInt32(byte) << 24
    for _ in 0..<8 { value = (value &<< 1) ^ (value & 0x8000_0000 == 0 ? 0 : 0x04c1_1db7) }
    return value
  }

  private static func checksum(_ bytes: Data) -> UInt32 {
    bytes.reduce(0) { crc, byte in (crc &<< 8) ^ crcTable[Int((crc >> 24) ^ UInt32(byte))] }
  }
}
