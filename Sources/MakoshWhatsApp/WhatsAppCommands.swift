import Foundation

public struct WhatsAppAction: Codable, Equatable, Sendable {
  public enum Operation: String, Codable, Sendable {
    case text, media, download, edit, revoke, react, forward, star, pin, archive
    case pinChat = "pin_chat"
    case mute, read, typing
    case callGroupStart = "call_group_start",callInvite = "call_invite",callRing = "call_ring"
    case callStart = "call_start"
    case callAccept = "call_accept"
    case callEnd = "call_end"
    case callMute = "call_mute"
    case callVideo = "call_video"
    case callReject = "call_reject"
    case location, contact, poll, vote, block, profile, avatar
    case userInfo = "user_info"
    case privacy
    case privacySet = "privacy_set"
    case setName = "set_name"
    case setAbout = "set_about"
    case groupInfo = "group_info"
    case groupName = "group_name"
    case groupAbout = "group_about"
    case groupUpdate = "group_update"
    case groupCreate = "group_create"
    case groupLeave = "group_leave"
    case groupLink = "group_link"
    case ephemeral
  }
  public var callContext: UUID?
  public var callEpoch: UInt64?
  public var op: Operation
  public var attempt: String
  public var text: String
  public var target: String
  public var reply: String?
  public var mentions: [String]
  public var to: String
  public var on: Bool
  public var duration: Int64
  public var path: String = "", kind: String = "", mime: String = "", name: String = ""
  public var options: [String] = []
  public var latitude: Double?, longitude: Double?
  public var category: String = "", value: String = ""
  public init(
    _ op: Operation, text: String = "", target: String = "", reply: String? = nil,
    mentions: [String] = [], to: String = "", on: Bool = false, duration: Int64 = 0
  ) {
    self.op = op
    attempt = UUID().uuidString.lowercased()
    self.text = text
    self.target = target
    self.reply = reply
    self.mentions = mentions
    self.to = to
    self.on = on
    self.duration = duration
  }
}
public struct WhatsAppMutationResult: Codable, Equatable, Sendable {
  public var stanza: String?
  public var pending: Bool?
  public var callEpoch:UInt64?
  public var info: WhatsAppPeerInfo?
  public init(stanza: String? = nil,callEpoch:UInt64?=nil) { self.stanza = stanza;self.callEpoch=callEpoch }
}
public struct WhatsAppPeerInfo: Codable, Equatable, Sendable {
  var avatar: WhatsAppAvatarDescriptor?
  public var name: String?, about: String?, jid: String?, link: String?
  public var blocked: Bool?, locked: Bool?, announce: Bool?
  public var rules: [String: String]?
  public var members: [WhatsAppMember]?
  public init() {}
}
public struct WhatsAppMember: Codable, Equatable, Identifiable, Sendable {
  public var jid: String, admin: Bool, me: Bool
  public var id: String { jid }
}
extension WhatsAppTransport {
  public func perform(chat: String, action: WhatsAppAction) async throws -> WhatsAppMutationResult {
    throw WhatsAppFailure.unavailable
  }
}
extension WhatsAppServing {
  public func send(accountID: UUID, chat: String, content: WhatsAppOutgoingContent) async throws
    -> WhatsAppOutgoing
  { throw WhatsAppFailure.unavailable }
  public func perform(accountID: UUID, chat: String, action: WhatsAppAction) async throws
    -> WhatsAppOutgoing
  { throw WhatsAppFailure.unavailable }
  public func resumeOutgoing(accountID: UUID, id: UUID) async throws -> WhatsAppOutgoing {
    throw WhatsAppFailure.unavailable
  }
  public func copyOutgoing(accountID: UUID, id: UUID) async throws -> WhatsAppOutgoing {
    throw WhatsAppFailure.unavailable
  }
  public func outgoing(accountID: UUID) async throws -> [WhatsAppOutgoing] {
    throw WhatsAppFailure.unavailable
  }
  public func resolveOutgoing(accountID: UUID, id: UUID, sent: Bool) async throws {
    throw WhatsAppFailure.unavailable
  }
}
extension WhatsAppWorker {
  public func send(accountID: UUID, chat: String, content: WhatsAppOutgoingContent) async throws
    -> WhatsAppOutgoing
  { try await sendContent(accountID: accountID, chat: chat, content: content, prepared: nil) }
  public func resumeOutgoing(accountID: UUID, id: UUID) async throws -> WhatsAppOutgoing {
    guard let repository, !synthetic else { throw WhatsAppFailure.closed }
    let row = try await repository.outgoing(id: id, accountID: accountID)
    guard row.state == .prepared, row.batchID == nil, row.content.action?.op.rawValue.hasPrefix("call_") != true else {
      throw WhatsAppFailure.invalid
    }
    return try await sendContent(
      accountID: accountID, chat: row.chat, content: row.content, prepared: row)
  }
  public func copyOutgoing(accountID: UUID, id: UUID) async throws -> WhatsAppOutgoing {
    guard let repository else { throw WhatsAppFailure.storage }
    let row = try await repository.outgoing(id: id, accountID: accountID)
    guard (row.state == .notSent || row.state == .rejected), row.content.action?.op.rawValue.hasPrefix("call_") != true else {
      throw WhatsAppFailure.invalid
    }
    var content = row.content
    content.composeRevision = nil
    return try await repository.prepareOutgoing(accountID: accountID, chat: row.chat, content: content)
  }
  func sendContent(
    accountID: UUID, chat: String, content: WhatsAppOutgoingContent, prepared: WhatsAppOutgoing?,
    batchLease: WhatsAppBatchLease? = nil, sourceGeneration: UInt64? = nil
  ) async throws -> WhatsAppOutgoing {
    guard content.files.count <= 1 else { throw WhatsAppFailure.invalid }
    try Task.checkCancellation()
    if synthetic {
      guard let repository else { throw WhatsAppFailure.storage }
      for id in content.files {
        guard let files else { throw WhatsAppFailure.storage }
        _ = try await files.prepared(id: id, accountID: accountID, chat: chat)
      }
      return try await repository.prepareOutgoing(
        accountID: accountID, chat: chat, content: content)
    }
    guard sessions[accountID] != nil, let generation = sourceGeneration ?? revisions[accountID],
      revisions[accountID] == generation else { throw WhatsAppFailure.closed }
    var action =
      content.action
      ?? WhatsAppAction(
        .text, text: content.text, reply: content.replyTo, mentions: content.mentions)
    var lease: WhatsAppFileLease?
    defer { lease?.remove() }
    if let id = content.files.first {
      guard let files else { throw WhatsAppFailure.storage }
      let file = try await files.prepared(id: id, accountID: accountID, chat: chat)
      try Task.checkCancellation()
      guard revisions[accountID] == generation else { throw WhatsAppFailure.closed }
      let opened = try await files.open(file)
      lease = opened
      try Task.checkCancellation()
      guard revisions[accountID] == generation else { throw WhatsAppFailure.closed }
      action.op = .media
      action.path = opened.url.path
      action.kind = file.kind
      action.mime = file.mime
      action.name = file.name
      action.on = file.voice == true
      action.duration = file.seconds ?? 0
    }
    return try await submit(
      accountID: accountID, chat: chat, content: content, action: action, prepared: prepared,
      batchLease: batchLease, sourceGeneration: generation)
  }
  public func perform(accountID: UUID, chat: String, action: WhatsAppAction) async throws
    -> WhatsAppOutgoing
  {
    if [.callEnd, .callReject].contains(action.op) { callRevisions[accountID, default: 0] &+= 1 }
    let callRevision: UInt64? =
      [.callStart, .callAccept,.callGroupStart,.callInvite,.callRing].contains(action.op) ? (callRevisions[accountID] ?? 0) : nil
    guard ![.media, .download, .text].contains(action.op), action.path.isEmpty else {
      throw WhatsAppFailure.invalid
    }
    let content = WhatsAppOutgoingContent(
      text: action.text, kind: action.op.rawValue, action: action)
    if synthetic {
      guard let repository else { throw WhatsAppFailure.storage }
      return try await repository.prepareOutgoing(
        accountID: accountID, chat: chat, content: content)
    }
    return try await submit(
      accountID: accountID, chat: chat, content: content, action: action, callRevision: callRevision
    )
  }
  func submit(
    accountID: UUID, chat: String, content: WhatsAppOutgoingContent, action: WhatsAppAction,
    callRevision: UInt64? = nil, prepared: WhatsAppOutgoing? = nil,
    batchLease: WhatsAppBatchLease? = nil, sourceGeneration: UInt64? = nil
  ) async throws -> WhatsAppOutgoing {
    guard let repository, let session = sessions[accountID], !synthetic
    else { throw WhatsAppFailure.closed }
    let generation = revisions[accountID]
    try Task.checkCancellation()
    guard sourceGeneration.map({ generation == $0 }) ?? true,
      try await session.status().linked, revisions[accountID] == generation else { throw WhatsAppFailure.closed }
    let draft: WhatsAppOutgoing
    if let prepared {
      guard prepared.accountID == accountID, prepared.chat.utf8.elementsEqual(chat.utf8),
        prepared.content == content
      else { throw WhatsAppFailure.invalid }
      draft = prepared
    } else {
      draft = try await repository.prepareOutgoing(
        accountID: accountID, chat: chat, content: content)
    }
    if content.composeRevision != nil, draft.state != .prepared { return draft }
    try Task.checkCancellation()
    guard revisions[accountID] == generation else { throw WhatsAppFailure.closed }
    let claimed = try await repository.claimOutgoing(id: draft.id, accountID: accountID, batchLease: batchLease)
    guard let attempt = claimed.attemptID else { throw WhatsAppFailure.storage }
    var action = action
    action.attempt = attempt.uuidString.lowercased()
    let result: WhatsAppMutationResult
    var invoked = false
    do {
      guard revisions[accountID] == generation,
        callRevision.map({ $0 == (callRevisions[accountID] ?? 0) }) ?? true
      else { throw WhatsAppFailure.closed }
      try Task.checkCancellation()
      invoked = true
      result = try await session.perform(chat: chat, action: action)
    } catch {
      // Only explicit pre-dispatch rejection is known not sent. Lost IPC,
      // cancellation, storage/COMMIT or any other error stays uncertain.
      let safe = !invoked || (error as? WhatsAppFailure) == .notAdmitted
      try await repository.settleOutgoing(
        id: draft.id, accountID: accountID, attemptID: attempt, outcome: safe ? .notSent : .unknown)
      throw error
    }
    try await repository.settleOutgoing(
      id: draft.id, accountID: accountID, attemptID: attempt, outcome: .sent, stanza: result.stanza,
      info: result.info,callEpoch:result.callEpoch)
    if [.callStart,.callGroupStart,.callAccept].contains(action.op),result.callEpoch != nil,result.stanza != nil,let generation,revisions[accountID]==generation {acceptedCalls[accountID]=(draft.id,generation)}
    return try await repository.outgoing(id: draft.id, accountID: accountID)
  }
  public func outgoing(accountID: UUID) async throws -> [WhatsAppOutgoing] {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.outgoing(accountID: accountID)
  }
  public func outgoingPage(accountID: UUID, before: WhatsAppOutgoingCursor?) async throws -> WhatsAppOutgoingPage {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.outgoingPage(accountID: accountID, before: before)
  }
  public func resolveOutgoing(accountID: UUID, id: UUID, sent: Bool) async throws {
    guard let repository else { throw WhatsAppFailure.storage }
    try await repository.resolveOutgoing(id: id, accountID: accountID, sent: sent)
  }
}
