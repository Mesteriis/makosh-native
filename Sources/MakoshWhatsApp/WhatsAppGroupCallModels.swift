import Foundation

public struct WhatsAppCallDeviceIdentity: Codable, Equatable, Hashable, Sendable {
  public let jid: String
  public let pid: UInt32?
  public init(jid: String, pid: UInt32? = nil) {
    self.jid = jid
    self.pid = pid
  }
  private enum CodingKeys: String, CodingKey { case jid, pid }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    jid = try c.decode(String.self, forKey: .jid)
    pid = try c.decodeIfPresent(UInt32.self, forKey: .pid)
    guard WhatsAppGroupCallTargets.isUser(jid, device: true) else { throw WhatsAppFailure.invalid }
  }
}
public struct WhatsAppCallParticipant: Codable, Equatable, Sendable, Identifiable {
  public let jid: String
  public let state: String?
  public let me: Bool?
  public let devices: [WhatsAppCallDeviceIdentity]
  public var id: String { jid }
  public init(
    jid: String, state: String? = nil, devices: [WhatsAppCallDeviceIdentity], me: Bool? = nil
  ) {
    self.jid = jid
    self.state = state
    self.devices = devices
    self.me = me
  }
  private enum CodingKeys: String, CodingKey { case jid, state, devices, me }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    jid = try c.decode(String.self, forKey: .jid)
    state = try c.decodeIfPresent(String.self, forKey: .state)
    me = try c.decodeIfPresent(Bool.self, forKey: .me)
    var items = try c.nestedUnkeyedContainer(forKey: .devices)
    var values: [WhatsAppCallDeviceIdentity] = []
    while !items.isAtEnd {
      guard values.count < 32 else { throw WhatsAppFailure.invalid }
      values.append(try items.decode(WhatsAppCallDeviceIdentity.self))
    }
    devices = values
    guard WhatsAppGroupCallTargets.isUser(jid),
      state.map({ $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true,
      Set(devices).count == devices.count
    else { throw WhatsAppFailure.invalid }
  }
}
public struct WhatsAppGroupCallSnapshot: Codable, Equatable, Sendable {
  public let groupJID: String?
  public let rosterRevision: UInt64
  public let participants: [WhatsAppCallParticipant]
  public let participantLimit: Int
  public init(
    groupJID: String?, rosterRevision: UInt64, participants: [WhatsAppCallParticipant],
    participantLimit: Int = 32
  ) {
    self.groupJID = groupJID
    self.rosterRevision = rosterRevision
    self.participants = participants
    self.participantLimit = participantLimit
  }
  private enum CodingKeys: String, CodingKey {
    case groupJID, rosterRevision, participants, participantLimit
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    groupJID = try c.decodeIfPresent(String.self, forKey: .groupJID)
    rosterRevision = try c.decode(UInt64.self, forKey: .rosterRevision)
    participantLimit = try c.decode(Int.self, forKey: .participantLimit)
    var items = try c.nestedUnkeyedContainer(forKey: .participants)
    var values: [WhatsAppCallParticipant] = []
    while !items.isAtEnd {
      guard values.count < 32 else { throw WhatsAppFailure.invalid }
      values.append(try items.decode(WhatsAppCallParticipant.self))
    }
    participants = values
    try validate()
  }
  public func validate() throws {
    guard (1...32).contains(participantLimit), participants.count <= 32,
      Set(participants.map(\.jid)).count == participants.count,
      participants.filter({ $0.state == "connected" }).count <= participantLimit
    else { throw WhatsAppFailure.invalid }
    if let groupJID { try WhatsAppGroupCallTargets.validateGroup(groupJID) }
    for p in participants {
      guard WhatsAppGroupCallTargets.isUser(p.jid), p.devices.count <= 32,
        Set(p.devices).count == p.devices.count,
        p.devices.allSatisfy({ WhatsAppGroupCallTargets.isUser($0.jid, device: true) }),
        p.state.map({ $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true
      else { throw WhatsAppFailure.invalid }
    }
  }
}
public enum WhatsAppGroupCallTargets {
  private static func userIdentity(_ value: String, device: Bool) -> String? {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard value.utf8.count <= 1024, parts.count == 2,
      ["lid", "s.whatsapp.net"].contains(String(parts[1])), !parts[0].isEmpty
    else { return nil }
    let address = parts[0].split(separator: ":", omittingEmptySubsequences: false)
    guard address.count <= 2, let base = address.first, !base.isEmpty else { return nil }
    var user = String(base)
    if address.count == 2 {
      guard device, !address[1].isEmpty, UInt16(address[1]) != nil,
        address[1].utf8.allSatisfy({ (48...57).contains($0) })
      else { return nil }
    } else if parts[1] == "s.whatsapp.net", let dot = user.lastIndex(of: "."),
      UInt16(user[user.index(after: dot)...]) != nil
    {
      // Pinned SDK: dotted PN suffix is a legacy device; LID dots belong to the user.
      guard device else { return nil }
      user = String(user[..<dot])
    }
    guard !user.isEmpty,
      user.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95].contains($0)
      })
    else { return nil }
    return user + "@" + parts[1]
  }
  public static func isUser(_ value: String, device: Bool = false) -> Bool {
    userIdentity(value, device: device) != nil
  }
  public static func validateGroup(_ value: String) throws {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard value.utf8.count <= 1024, parts.count == 2, parts[1] == "g.us", !parts[0].isEmpty,
      parts[0].utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
      })
    else { throw WhatsAppFailure.invalid }
  }
  public static func validate(_ targets: [String], ownAliases: [String] = []) throws -> [String] {
    guard (2...31).contains(targets.count), Set(targets).count == targets.count,
      targets.allSatisfy({ isUser($0) })
    else { throw WhatsAppFailure.invalid }
    // These are known source aliases only; PN↔LID resolution stays with the SDK.
    var own = Set<String>()
    for alias in ownAliases {
      guard let identity = userIdentity(alias, device: true) else { throw WhatsAppFailure.invalid }
      own.insert(identity)
    }
    guard targets.allSatisfy({ !own.contains($0) }) else { throw WhatsAppFailure.invalid }
    return targets
  }
}
extension WhatsAppServing {
  public func startGroupCall(
    accountID: UUID, groupJID: String, participants: [String], video: Bool, callContext: UUID?
  ) async throws -> WhatsAppOutgoing {
    try await startGroupCall(
      accountID: accountID, groupJID: groupJID, participants: participants, video: video)
  }
  public func startGroupCall(accountID: UUID, groupJID: String, participants: [String], video: Bool)
    async throws -> WhatsAppOutgoing
  { throw WhatsAppFailure.unavailable }
  public func inviteCallParticipant(
    accountID: UUID, callID: String, epoch: UInt64, jid: String, ringOnly: Bool
  ) async throws -> WhatsAppOutgoing { throw WhatsAppFailure.unavailable }
}
