import Foundation

struct WhatsAppPCMFrames: Sendable {
  private var partial: [Int16] = []
  private var frames: [[Int16]] = []
  mutating func append(_ samples: [Int16]) {
    guard samples.count <= 192_000 else { return }
    partial.append(contentsOf: samples)
    var offset = 0
    while partial.count - offset >= 960 {
      frames.append(Array(partial[offset..<offset + 960]))
      offset += 960
      if frames.count > 3 { frames.removeFirst() }
    }
    if offset > 0 { partial.removeFirst(offset) }
  }
  mutating func take() -> [[Int16]] {
    let result = frames
    frames = []
    return result
  }
}
