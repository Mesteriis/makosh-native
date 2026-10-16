import Foundation

public struct WhatsAppCallSnapshot: Codable, Equatable, Sendable, Identifiable {
  public var group: WhatsAppGroupCallSnapshot?
  public var id: String
  public var epoch: UInt64
  public var peer: String, state: String
  public var incoming: Bool, video: Bool, remoteVideo: Bool, videoRequested: Bool, muted: Bool
  public init(
    id: String, epoch: UInt64, peer: String, state: String, incoming: Bool, video: Bool,
    remoteVideo: Bool, videoRequested: Bool, muted: Bool,group: WhatsAppGroupCallSnapshot? = nil
  ) {
    self.group=group
    self.id = id
    self.epoch = epoch
    self.peer = peer
    self.state = state
    self.incoming = incoming
    self.video = video
    self.remoteVideo = remoteVideo
    self.videoRequested = videoRequested
    self.muted = muted
  }
  public var ended: Bool { ["ended", "failed"].contains(state) }
}
public struct WhatsAppCallExchange: Codable, Sendable {
  public let id: String
  public let epoch: UInt64
  public var audio: [[Int16]]
  public var video: [UInt8]
  public var visibleStreams:[WhatsAppCallStreamID]?
  public var visibilityRevision:UInt64?
  public init(id: String, epoch: UInt64, audio: [[Int16]] = [], video: [UInt8] = [],visibleStreams:[WhatsAppCallStreamID]?=nil,visibilityRevision:UInt64?=nil) {
    self.visibleStreams=visibleStreams;self.visibilityRevision=visibilityRevision
    self.id = id
    self.epoch = epoch
    self.audio = audio
    self.video = video
  }
}
public struct WhatsAppCallOutput: Codable, Sendable {
  public var audio: [[Int16]],video:[UInt8]?,keyframe:Bool,orientation:UInt8
  public var videos:[WhatsAppParticipantVideo]
  public var visibilityRevision:UInt64?
  public init(audio:[[Int16]],video:[UInt8]?,keyframe:Bool,orientation:UInt8,videos:[WhatsAppParticipantVideo]=[],visibilityRevision:UInt64?=nil) {self.audio=audio;self.video=video;self.keyframe=keyframe;self.orientation=orientation;self.videos=videos;self.visibilityRevision=visibilityRevision}
  private enum CodingKeys:String,CodingKey {case audio,video,keyframe,orientation,videos,visibilityRevision}
  public init(from decoder:Decoder) throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    audio=try c.decode([[Int16]].self,forKey:.audio);video=try c.decodeIfPresent([UInt8].self,forKey:.video);keyframe=try c.decode(Bool.self,forKey:.keyframe);orientation=try c.decode(UInt8.self,forKey:.orientation);visibilityRevision=try c.decodeIfPresent(UInt64.self,forKey:.visibilityRevision)
    var values:[WhatsAppParticipantVideo]=[]
    if c.contains(.videos) {var a=try c.nestedUnkeyedContainer(forKey:.videos);while !a.isAtEnd {guard values.count<4 else {throw WhatsAppFailure.invalid};values.append(try a.decode(WhatsAppParticipantVideo.self))}}
    videos=values
    guard audio.count<=8,audio.allSatisfy({$0.count<=1920}),video.map({$0.count<=256*1024}) ?? true,orientation<=3 else {throw WhatsAppFailure.invalid}
  }
}
extension WhatsAppTransport {
  public func callMedia(_ request: WhatsAppCallExchange) async throws -> WhatsAppCallOutput {
    throw WhatsAppFailure.unavailable
  }
}
extension WhatsAppServing {
  public func callMedia(accountID: UUID, request: WhatsAppCallExchange) async throws
    -> WhatsAppCallOutput
  { throw WhatsAppFailure.unavailable }
}
extension WhatsAppWorker {
  public func callMedia(accountID: UUID, request: WhatsAppCallExchange) async throws
    -> WhatsAppCallOutput
  {
    guard let session = sessions[accountID], !synthetic else { throw WhatsAppFailure.closed }
    let generation = revisions[accountID]
    let result = try await session.callMedia(request)
    guard revisions[accountID] == generation else { throw CancellationError() }
    return result
  }
}

extension WhatsAppServing {
  public func callSnapshots() async throws -> [UUID: WhatsAppCallSnapshot] { [:] }
}
extension WhatsAppWorker {
  public func callSnapshots() async throws -> [UUID: WhatsAppCallSnapshot] {
    var values: [UUID: WhatsAppCallSnapshot] = [:]
    for (id, session) in sessions {
      let revision = revisions[id]
      let status = try await session.status()
      if revisions[id] == revision, let call = status.call { values[id] = call }
    }
    return values
  }
}
