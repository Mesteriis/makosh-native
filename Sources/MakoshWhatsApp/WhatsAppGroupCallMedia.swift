import CoreGraphics
import Foundation

public struct WhatsAppCallStreamID: Codable, Hashable, Sendable {
  public let sender: String, device: String
  public let pid: UInt32?
  public init(sender: String, device: String, pid: UInt32?) {
    self.sender = sender
    self.device = device
    self.pid = pid
  }
  func validate() throws {
    guard WhatsAppGroupCallTargets.isUser(sender),
      WhatsAppGroupCallTargets.isUser(device, device: true)
    else { throw WhatsAppFailure.invalid }
  }
  private enum CodingKeys: String, CodingKey { case sender, device, pid }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    sender = try c.decode(String.self, forKey: .sender)
    device = try c.decode(String.self, forKey: .device)
    pid = try c.decodeIfPresent(UInt32.self, forKey: .pid)
    try validate()
  }
}
public struct WhatsAppParticipantVideo: Codable, Sendable {
  public let stream: WhatsAppCallStreamID
  public var keyframe: Bool, orientation: UInt8, bytes: [UInt8]
  public init(stream: WhatsAppCallStreamID, keyframe: Bool, orientation: UInt8, bytes: [UInt8]) {
    self.stream = stream
    self.keyframe = keyframe
    self.orientation = orientation
    self.bytes = bytes
  }
  private enum CodingKeys: String, CodingKey { case stream, keyframe, orientation, bytes }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    stream = try c.decode(WhatsAppCallStreamID.self, forKey: .stream)
    keyframe = try c.decode(Bool.self, forKey: .keyframe)
    orientation = try c.decode(UInt8.self, forKey: .orientation)
    var a = try c.nestedUnkeyedContainer(forKey: .bytes)
    var b: [UInt8] = []
    while !a.isAtEnd {
      guard b.count < 256 * 1024 else { throw WhatsAppFailure.invalid }
      b.append(try a.decode(UInt8.self))
    }
    bytes = b
    guard orientation <= 3 else { throw WhatsAppFailure.invalid }
  }
}
protocol WhatsAppParticipantDecoding: AnyObject, Sendable {
  var onDecoded: (@Sendable (CGImage) -> Void)? { get set }
  func decode(_ data: Data, orientation: UInt8)
  func stop() async
}
extension WhatsAppH264Codec: WhatsAppParticipantDecoding {}
public struct WhatsAppGroupCallImage: @unchecked Sendable {
  public let stream: WhatsAppCallStreamID
  public let image: CGImage
}
public struct WhatsAppCallVisibility: Sendable {
  public let streams: [WhatsAppCallStreamID]
  public let revision: UInt64
}
public actor WhatsAppGroupCallMedia {
  private struct Entry {
    let decoder: any WhatsAppParticipantDecoding
    let nonce: UUID
    var image: CGImage?
  }
  private let factory: @Sendable () -> any WhatsAppParticipantDecoding
  private var streams: [WhatsAppCallStreamID] = [], revision: UInt64 = 0
  private var callID: String?, epoch: UInt64 = 0, closed = false, rosterRevision: UInt64 = 0
  private var entries: [WhatsAppCallStreamID: Entry] = [:]
  public init() { factory = { WhatsAppH264Codec(tileSize: CGSize(width: 640, height: 480)) } }
  init(factory: @escaping @Sendable () -> any WhatsAppParticipantDecoding) {
    self.factory = factory
  }
  public func setVisibleStreams(_ ids: [WhatsAppCallStreamID], callID: String, epoch: UInt64)
    async throws
  {
    guard !closed, ids.count <= 9, Set(ids).count == ids.count, !callID.isEmpty else {
      throw WhatsAppFailure.invalid
    }
    for id in ids { try id.validate() }
    let same = self.callID == callID && self.epoch == epoch
    guard !same || streams != ids else { return }
    if !same { rosterRevision = 0 }
    self.callID = callID
    self.epoch = epoch
    streams = ids
    revision &+= 1
    let retired = entries.filter { !same || !ids.contains($0.key) }
    for (id, _) in retired { entries.removeValue(forKey: id) }
    for (_, entry) in retired { await entry.decoder.stop() }
  }
  public func selection() -> WhatsAppCallVisibility { .init(streams: streams, revision: revision) }
  public func receive(
    _ output: WhatsAppCallOutput, callID: String, epoch: UInt64, roster: WhatsAppGroupCallSnapshot,
    expectedVisibilityRevision: UInt64? = nil
  ) async {
    guard !closed, self.callID == callID, self.epoch == epoch, output.videos.count <= 4,
      expectedVisibilityRevision.map({ $0 == revision }) ?? true,
      output.visibilityRevision.map({ $0 == revision }) ?? true, (try? roster.validate()) != nil
    else { return }
    guard roster.rosterRevision >= rosterRevision else { return }
    rosterRevision = roster.rosterRevision
    let allowed = Set(
      roster.participants.filter { $0.me != true && $0.state == "connected" }.flatMap { p in
        p.devices.map { WhatsAppCallStreamID(sender: p.jid, device: $0.jid, pid: $0.pid) }
      })
    let observed = revision
    let retired = entries.filter { !allowed.contains($0.key) }
    for (id, _) in retired { entries.removeValue(forKey: id) }
    for (_, entry) in retired { await entry.decoder.stop() }
    guard !closed, self.callID == callID, self.epoch == epoch, observed == revision else { return }
    for frame in output.videos
    where streams.contains(frame.stream) && allowed.contains(frame.stream) {
      guard !frame.bytes.isEmpty, frame.bytes.count <= 256 * 1024, frame.orientation <= 3 else {
        continue
      }
      let data = Data(frame.bytes)
      let units = WhatsAppH264Codec.units(Data(frame.bytes))
      guard !units.isEmpty, units.count <= 256,
        units.allSatisfy({
          guard let first = $0.first else { return false }
          return first & 0x80 == 0 && (1...23).contains(first & 31)
        })
      else { continue }
      if entries[frame.stream] == nil {
        let kinds = Set(units.compactMap { $0.first.map { $0 & 31 } })
        guard frame.keyframe, kinds.isSuperset(of: [5, 7, 8]), entries.count < 9 else { continue }
        let decoder = factory()
        let nonce = UUID()
        let stream = frame.stream
        decoder.onDecoded = { [weak self] image in
          Task {
            await self?.publish(image, stream: stream, nonce: nonce, callID: callID, epoch: epoch)
          }
        }
        entries[stream] = Entry(decoder: decoder, nonce: nonce, image: nil)
      }
      entries[frame.stream]?.decoder.decode(data, orientation: frame.orientation)
    }
  }
  private func publish(
    _ image: CGImage, stream: WhatsAppCallStreamID, nonce: UUID, callID: String, epoch: UInt64
  ) {
    guard !closed, self.callID == callID, self.epoch == epoch, streams.contains(stream),
      entries[stream]?.nonce == nonce, image.width <= 640, image.height <= 480
    else { return }
    entries[stream]?.image = image
  }
  public func images() -> [WhatsAppGroupCallImage] {
    streams.compactMap { id in entries[id]?.image.map { .init(stream: id, image: $0) } }
  }
  public func stop() async {
    closed = true
    revision &+= 1
    callID = nil
    streams = []
    let retired = Array(entries.values)
    entries.removeAll()
    for entry in retired { await entry.decoder.stop() }
  }
}
