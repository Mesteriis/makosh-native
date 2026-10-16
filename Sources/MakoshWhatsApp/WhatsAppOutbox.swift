import Foundation

public struct WhatsAppOutgoingContent: Codable, Equatable, Sendable {
  public var text: String
  public var replyTo: String?
  public var files: [UUID]
  public var kind: String
  public var mentions: [String]
  public var action: WhatsAppAction?
  public var composeRevision: UInt64?
  public init(
    text: String, replyTo: String? = nil, files: [UUID] = [], kind: String = "text",
    mentions: [String] = [], action: WhatsAppAction? = nil, composeRevision: UInt64? = nil
  ) {
    self.text = text
    self.replyTo = replyTo
    self.files = files
    self.kind = kind
    self.mentions = mentions
    self.action = action
    self.composeRevision = composeRevision
  }
}
public struct WhatsAppOutgoing: Codable, Equatable, Identifiable, Sendable {
  public enum State: String, Codable, Sendable {
    case prepared, dispatching, unknown, sent, notSent, rejected
  }
  public let id: UUID
  public let accountID: UUID
  public let chat: String
  public let content: WhatsAppOutgoingContent
  public let created: Date
  public var attemptID: UUID?
  public var stanza: String?
  public var rejection: WhatsAppServerRejection?
  public var info: WhatsAppPeerInfo?
  public var state: State
  public var batchID: UUID?
  public var callEpoch:UInt64? = nil
}
public enum WhatsAppOutgoingOutcome: Sendable { case sent, notSent, unknown }

extension WhatsAppRepository {
  public func prepareOutgoing(accountID: UUID, chat: String, content: WhatsAppOutgoingContent)
    throws -> WhatsAppOutgoing
  {
    try validateOutgoing(chat: chat, content: content)
    let db = try db()
    return try db.transaction {
      guard try db.accounts().contains(where: { $0.id == accountID }) else { throw WhatsAppFailure.invalid }
      let draft = try checkedCompose(accountID: accountID, chat: chat, content: content, db: db)
      if let admission = draft?.admitted {
        guard case .outgoing(let id) = admission else { throw WhatsAppFailure.invalid }
        return try readOutgoing(id, accountID: accountID, db: db)
      }
      let value = WhatsAppOutgoing(
        id: UUID(), accountID: accountID, chat: chat, content: content, created: Date(), state: .prepared)
      try storeOutgoing(value, db: db, insert: true)
      if var draft { draft.admitted = .outgoing(value.id); try storeCompose(draft, db: db) }
      return value
    }
  }
  func validateOutgoing(chat: String, content: WhatsAppOutgoingContent) throws {
    guard !chat.isEmpty, chat.utf8.count <= 1024, !chat.utf8.contains(0),
      !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !content.files.isEmpty || content.action != nil,
      content.text.utf8.count <= 65536, content.files.count <= 10,
      Set(content.files).count == content.files.count, content.mentions.count <= 100,
      content.mentions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
      content.replyTo.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true
    else { throw WhatsAppFailure.invalid }
  }
  public func outgoing(accountID: UUID) throws -> [WhatsAppOutgoing] {
    try outgoingPage(accountID: accountID, before: nil).values
  }
  public func outgoingPage(accountID: UUID, before: WhatsAppOutgoingCursor?, limit: Int = 50) throws -> WhatsAppOutgoingPage {
    guard (1...100).contains(limit) else { throw WhatsAppFailure.invalid }
    let db = try db()
    var params = [accountID.uuidString]
    var predicate = "account=$1"
    if let before {
      params += [String(before.timestamp), before.token]
      predicate += " AND (ts<$2::bigint OR (ts=$2::bigint AND token<$3))"
    }
    let rows = try db.query("SELECT token,ciphertext,ts FROM \(db.outboxTable) WHERE \(predicate) ORDER BY ts DESC,token DESC LIMIT \(limit + 1)", params)
    let page = Array(rows.prefix(limit))
    let values = try page.map { row -> WhatsAppOutgoing in
      var value: WhatsAppOutgoing = try db.decode(row[1], token: row[0])
      if value.state == .dispatching && !db.outgoingOwners.contains(value.id) { value.state = .unknown }
      return value
    }
    let next = rows.count > limit ? page.last.flatMap { row in Int64(row[2]).map { WhatsAppOutgoingCursor(timestamp: $0, token: row[0]) } } : nil
    return .init(values: values, next: next)
  }
  func bindOutgoingResource(accountID: UUID, chat: String, stanza: String, resource: String) throws
    -> Bool
  {
    let db = try db()
    let token = db.token([accountID.uuidString, "outgoing-resource", chat, stanza])
    guard try !outgoingFileIDs(accountID: accountID, chat: chat, stanza: stanza).isEmpty else {
      return false
    }
    _ = try db.query(
      "INSERT INTO \(db.preferencesTable) VALUES($1,$2) ON CONFLICT(token) DO NOTHING",
      [token, try db.seal(resource, token: token)])
    return try outgoingResourceMatches(
      accountID: accountID, chat: chat, stanza: stanza, resource: resource)
  }
  func outgoingResourceMatches(accountID: UUID, chat: String, stanza: String, resource: String)
    throws -> Bool
  {
    let db = try db()
    let token = db.token([accountID.uuidString, "outgoing-resource", chat, stanza])
    guard
      let row = try db.query(
        "SELECT ciphertext FROM \(db.preferencesTable) WHERE token=$1", [token]
      ).first
    else { return false }
    let saved: String = try db.decode(row[0], token: token)
    return saved.utf8.elementsEqual(resource.utf8)
  }
  func outgoingFileIDs(accountID: UUID, chat: String, stanza: String) throws -> [UUID] {
    let db = try db()
    let token = db.token([accountID.uuidString, "outgoing-files", chat, stanza])
    guard
      let row = try db.query(
        "SELECT ciphertext FROM \(db.preferencesTable) WHERE token=$1", [token]
      ).first
    else { return [] }
    return try db.decode(row[0], token: token)
  }
  func outgoing(id: UUID, accountID: UUID) throws -> WhatsAppOutgoing {
    try readOutgoing(id, accountID: accountID, db: db())
  }
  public func claimOutgoing(id: UUID, accountID: UUID, batchLease: WhatsAppBatchLease? = nil) throws -> WhatsAppOutgoing {
    let db = try db()
    return try db.transaction {
      var value: WhatsAppOutgoing
      if let batchLease { value = try batchChildForClaim(id: id, accountID: accountID, lease: batchLease, db: db) }
      else {
        value = try readOutgoing(id, accountID: accountID, db: db)
        guard value.batchID == nil else { throw WhatsAppFailure.invalid }
      }
      guard value.state == .prepared, !db.outgoingOwners.contains(id), try lockOutgoing(id, db: db)
      else { throw WhatsAppFailure.invalid }
      do {
        if value.batchID == nil { value.attemptID = UUID() }
        guard value.attemptID != nil else { throw WhatsAppFailure.storage }
        value.state = .dispatching
        if let attempt = value.attemptID { value.stanza = "MK" + attempt.uuidString.replacingOccurrences(of: "-", with: "").uppercased() }
        if let attempt = value.attemptID, !value.content.files.isEmpty {
          let stanza =
            "MK" + attempt.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
          let token = db.token([accountID.uuidString, "outgoing-files", value.chat, stanza])
          _ = try db.query(
            "INSERT INTO \(db.preferencesTable) VALUES($1,$2) ON CONFLICT(token) DO NOTHING",
            [token, try db.seal(value.content.files, token: token)])
        }
        try storeOutgoing(value, db: db)
        db.outgoingOwners.insert(id)
        return value
      } catch {
        try? unlockOutgoing(id, db: db)
        throw error
      }
    }
  }
  public func settleOutgoing(
    id: UUID, accountID: UUID, attemptID: UUID, outcome: WhatsAppOutgoingOutcome,
    stanza: String? = nil, info: WhatsAppPeerInfo? = nil,callEpoch:UInt64?=nil
  ) throws {
    let db = try db()
    guard db.outgoingOwners.contains(id) else { throw WhatsAppFailure.invalid }
    var matched = false
    defer {
      if matched {
        db.outgoingOwners.remove(id)
        try? unlockOutgoing(id, db: db)
      }
    }
    try db.transaction {
      var value = try readOutgoing(id, accountID: accountID, db: db)
      guard value.state == .dispatching, value.attemptID == attemptID else {
        throw WhatsAppFailure.invalid
      }
      matched = true
      switch outcome {
      case .sent: value.state = .sent
      case .notSent: value.state = .notSent
      case .unknown: value.state = .unknown
      }
      value.stanza = stanza ?? value.stanza
      value.info = info
      value.callEpoch=callEpoch
      if let stanza = value.stanza, let rejection = try rejection(accountID: accountID, chat: value.chat, stanza: stanza, db: db) {
        value.rejection = rejection
        value.state = .rejected
      }
      try storeOutgoing(value, db: db)
    }
  }
  /// Explicit resolution never issues a protocol command. A live dispatch in
  /// any process owns a session advisory lock and cannot be resolved here.
  public func resolveOutgoing(id: UUID, accountID: UUID, sent: Bool) throws {
    let db = try db()
    guard !db.outgoingOwners.contains(id) else { throw WhatsAppFailure.invalid }
    try db.transaction {
      var value = try readOutgoing(id, accountID: accountID, db: db)
      guard value.state == .unknown || value.state == .dispatching
      else { throw WhatsAppFailure.invalid }
      if let batch = value.batchID, try !lockBatch(batch, db: db) { throw WhatsAppFailure.owned }
      defer { if let batch = value.batchID { try? unlockBatch(batch, db: db) } }
      guard try lockOutgoing(id, db: db) else { throw WhatsAppFailure.invalid }
      defer { try? unlockOutgoing(id, db: db) }
      value.state = sent ? .sent : .notSent
      try storeOutgoing(value, db: db)
    }
  }
  func recordRejection(accountID: UUID, message: WhatsAppMessage, db: WhatsAppPostgres) throws {
    guard message.outgoing, let value = message.details?.rejection else { return }
    let fact = db.token([accountID.uuidString, "server-nack", message.chat, message.stanza])
    _ = try db.query("INSERT INTO \(db.preferencesTable) VALUES($1,$2) ON CONFLICT(token) DO NOTHING", [fact, try db.seal(value, token: fact)])
    let stanza = db.token([accountID.uuidString, message.chat, message.stanza])
    for row in try db.query("SELECT token,ciphertext FROM \(db.outboxTable) WHERE account=$1 AND stanza_token=$2", [accountID.uuidString, stanza]) {
      var outgoing: WhatsAppOutgoing = try db.decode(row[1], token: row[0])
      // A live owner settles using the source fact; never overwrite dispatching
      // and undermine its attempt/lease checks from the journal consumer.
      if outgoing.state == .sent || outgoing.state == .unknown {
        outgoing.state = .rejected
        outgoing.rejection = value
        try storeOutgoing(outgoing, db: db)
      }
    }
  }
  private func rejection(accountID: UUID, chat: String, stanza: String, db: WhatsAppPostgres) throws -> WhatsAppServerRejection? {
    let token = db.token([accountID.uuidString, "server-nack", chat, stanza])
    guard let row = try db.query("SELECT ciphertext FROM \(db.preferencesTable) WHERE token=$1", [token]).first else { return nil }
    return try db.decode(row[0], token: token)
  }
  func readOutgoing(_ id: UUID, accountID: UUID, db: WhatsAppPostgres) throws
    -> WhatsAppOutgoing
  {
    let token = db.token([accountID.uuidString, "outgoing", id.uuidString])
    guard
      let row = try db.query(
        "SELECT ciphertext FROM \(db.outboxTable) WHERE token=$1 AND account=$2 FOR UPDATE",
        [token, accountID.uuidString]
      ).first
    else { throw WhatsAppFailure.invalid }
    let value: WhatsAppOutgoing = try db.decode(row[0], token: token)
    guard value.id == id, value.accountID == accountID else { throw WhatsAppFailure.storage }
    return value
  }
  func storeOutgoing(_ value: WhatsAppOutgoing, db: WhatsAppPostgres, insert: Bool = false)
    throws
  {
    let token = db.token([value.accountID.uuidString, "outgoing", value.id.uuidString])
    if insert {
      _ = try db.query(
        "INSERT INTO \(db.outboxTable)(token,account,ts,ciphertext) VALUES($1,$2,$3::bigint,$4)",
        [
          token, value.accountID.uuidString,
          String(Int64(value.created.timeIntervalSince1970 * 1000)),
          try db.seal(value, token: token),
        ])
    } else {
      _ = try db.query(
        "UPDATE \(db.outboxTable) SET ciphertext=$2 WHERE token=$1",
        [token, try db.seal(value, token: token)])
    }
    if let stanza = value.stanza {
      _ = try db.query("UPDATE \(db.outboxTable) SET stanza_token=$2 WHERE token=$1", [token, db.token([value.accountID.uuidString, value.chat, stanza])])
    }
  }
  private func lockOutgoing(_ id: UUID, db: WhatsAppPostgres) throws -> Bool {
    try db.query("SELECT pg_try_advisory_lock(hashtextextended($1,17402))", [id.uuidString]).first?
      .first == "t"
  }
  private func unlockOutgoing(_ id: UUID, db: WhatsAppPostgres) throws {
    _ = try db.query("SELECT pg_advisory_unlock(hashtextextended($1,17402))", [id.uuidString])
  }
}

public struct WhatsAppOutgoingCursor: Sendable, Equatable {
  public let timestamp: Int64
  public let token: String
}
public struct WhatsAppOutgoingPage: Sendable {
  public let values: [WhatsAppOutgoing]
  public let next: WhatsAppOutgoingCursor?
  public init(values: [WhatsAppOutgoing], next: WhatsAppOutgoingCursor?) { self.values = values; self.next = next }
}
