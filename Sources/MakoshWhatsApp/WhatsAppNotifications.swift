import Foundation

public struct WhatsAppNotificationRule: Codable, Equatable, Sendable {
  public var show = true, preview = true, sound = true, foreground = true
  public init() {}
  func restricting(_ other: Self) -> Self {
    var r = self
    r.show = show && other.show
    r.preview = preview && other.preview
    r.sound = sound && other.sound
    r.foreground = foreground && other.foreground
    return r
  }
}
public struct WhatsAppNotificationEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let thread: String
  public let accountID: UUID
  public let chat: String
  public let messageID: String
  public let title: String
  public let body: String
  public let timestamp: Int64
}
extension WhatsAppRepository {
  public func setNotificationRule(_ rule: WhatsAppNotificationRule, accountID: UUID?, chat: String?)
    throws
  {
    guard
      chat == nil || (accountID != nil && chat?.isEmpty == false && (chat?.utf8.count ?? 0) <= 1024)
    else { throw WhatsAppFailure.invalid }
    let db = try db()
    if let accountID {
      guard try db.accounts().contains(where: { $0.id == accountID }) else {
        throw WhatsAppFailure.invalid
      }
    }
    let token = notificationScope(accountID, chat: chat, db: db)
    _ = try db.query(
      "INSERT INTO \(db.preferencesTable) VALUES($1,$2) ON CONFLICT(token) DO UPDATE SET ciphertext=excluded.ciphertext",
      [token, try db.seal(rule, token: token)])
  }
  public func savedNotificationRule(accountID: UUID?, chat: String?) throws
    -> WhatsAppNotificationRule
  {
    try savedNotificationRule(accountID, chat: chat, db: db())
  }
  public func notificationRule(accountID: UUID, chat: String) throws -> WhatsAppNotificationRule {
    try effectiveNotificationRule(accountID, chat: chat, db: db())
  }
  private func notificationScope(_ accountID: UUID?, chat: String?, db: WhatsAppPostgres) -> String
  {
    db.token([
      "notification-rule", chat != nil ? "chat" : accountID != nil ? "account" : "global",
      accountID?.uuidString ?? "", chat ?? "",
    ])
  }
  private func savedNotificationRule(_ accountID: UUID?, chat: String?, db: WhatsAppPostgres) throws
    -> WhatsAppNotificationRule
  {
    let token = notificationScope(accountID, chat: chat, db: db)
    guard
      let row = try db.query(
        "SELECT ciphertext FROM \(db.preferencesTable) WHERE token=$1", [token]
      ).first
    else { return .init() }
    return try db.decode(row[0], token: token)
  }
  private func effectiveNotificationRule(_ accountID: UUID, chat: String, db: WhatsAppPostgres)
    throws -> WhatsAppNotificationRule
  {
    var rule = try savedNotificationRule(nil, chat: nil, db: db).restricting(
      savedNotificationRule(accountID, chat: nil, db: db)
    ).restricting(savedNotificationRule(accountID, chat: chat, db: db))
    if let row = try db.query(
      "SELECT ciphertext FROM \(db.chatsTable) WHERE token=$1",
      [db.token([accountID.uuidString, chat])]
    ).first {
      let source: WhatsAppChat = try db.decode(
        row[0], token: db.token([accountID.uuidString, chat]))
      if let until = source.mutedUntil, until < 0 || until > Int64(Date().timeIntervalSince1970) {
        rule.show = false
      }
    }
    return rule
  }
  func admitNotification(
    _ entry: WhatsAppJournalEntry, accountID: UUID, firstSeen: Bool, db: WhatsAppPostgres
  ) throws {
    let message = entry.message
    let now = Int64(Date().timeIntervalSince1970)
    guard firstSeen, entry.notify == true, !entry.history, !message.outgoing, !message.edited,
      !message.deleted,
      message.chat != "status@broadcast", !["protocol", "reaction"].contains(message.kind),
      message.timestamp <= now + 60, message.timestamp >= now - 120
    else { return }
    let token = db.token([accountID.uuidString, "notification", String(entry.sequence)])
    let chatToken = db.token([accountID.uuidString, message.chat])
    var title = "WhatsApp"
    if let row = try db.query("SELECT ciphertext FROM \(db.chatsTable) WHERE token=$1", [chatToken])
      .first
    {
      let source: WhatsAppChat = try db.decode(row[0], token: chatToken)
      if source.name != source.id { title = source.name }
    }
    let value = WhatsAppNotificationEvent(
      id: token, thread: db.token(["notification-thread", accountID.uuidString, message.chat]),
      accountID: accountID, chat: message.chat, messageID: message.id,
      title: message.details?.protected == true ? "WhatsApp" : String(title.prefix(256)),
      body: message.details?.protected == true
        ? "Новое защищённое сообщение"
        : String((message.text.isEmpty ? message.kind : message.text).prefix(512)),
      timestamp: message.timestamp)
    let rule = try effectiveNotificationRule(accountID, chat: message.chat, db: db)
    _ = try db.query(
      "INSERT INTO \(db.notificationsTable) VALUES($1,$2,$3::bigint,$4,$5)",
      [
        token, accountID.uuidString, String(entry.sequence), rule.show ? "queued" : "suppressed",
        try db.seal(value, token: token),
      ])
  }
  public func claimNotifications(accountID: UUID) throws -> [WhatsAppNotificationEvent] {
    let db = try db()
    return try db.transaction {
      let rows = try db.query(
        "SELECT token,ciphertext FROM \(db.notificationsTable) WHERE account=$1 AND state='queued' ORDER BY sequence LIMIT 100 FOR UPDATE SKIP LOCKED",
        [accountID.uuidString])
      var events: [WhatsAppNotificationEvent] = []
      for row in rows {
        let event: WhatsAppNotificationEvent = try db.decode(row[1], token: row[0])
        // Consume muted events too. Enabling a rule cannot replay history.
        if event.timestamp >= Int64(Date().timeIntervalSince1970) - 120,
          event.timestamp <= Int64(Date().timeIntervalSince1970) + 60,
          try effectiveNotificationRule(accountID, chat: event.chat, db: db).show
        {
          events.append(event)
        }
        _ = try db.query(
          "UPDATE \(db.notificationsTable) SET state='consumed' WHERE token=$1", [row[0]])
      }
      return events
    }
  }
  public func notificationIsCurrent(_ event: WhatsAppNotificationEvent) throws -> Bool {
    let db = try db()
    guard try db.accounts().contains(where: { $0.id == event.accountID }),
      try effectiveNotificationRule(event.accountID, chat: event.chat, db: db).show
    else { return false }
    let token = db.token([event.accountID.uuidString, event.chat, event.messageID])
    guard
      let row = try db.query("SELECT ciphertext FROM \(db.messagesTable) WHERE token=$1", [token])
        .first
    else { return false }
    let message: WhatsAppMessage = try db.decode(row[0], token: token)
    guard !message.deleted, !message.outgoing else { return false }
    let chatToken = db.token([event.accountID.uuidString, event.chat])
    guard
      let row = try db.query("SELECT ciphertext FROM \(db.chatsTable) WHERE token=$1", [chatToken])
        .first
    else { return false }
    let chat: WhatsAppChat = try db.decode(row[0], token: chatToken)
    return chat.unread > 0
  }
}

extension WhatsAppRepository {
  /// Claim the opaque activation exactly once across windows and restarts.
  public func activateNotification(token: String) throws -> WhatsAppNotificationEvent? {
    guard token.count == 64,
      token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw WhatsAppFailure.invalid }
    let db = try db()
    return try db.transaction {
      guard
        let row = try db.query(
          "SELECT ciphertext FROM \(db.notificationsTable) WHERE token=$1 AND state='consumed' FOR UPDATE",
          [token]
        ).first
      else { return nil }
      let event: WhatsAppNotificationEvent = try db.decode(row[0], token: token)
      guard try notificationIsCurrent(event) else { return nil }
      _ = try db.query(
        "UPDATE \(db.notificationsTable) SET state='activated' WHERE token=$1", [token])
      return event
    }
  }
}
extension WhatsAppServing {
  public func activateNotification(token: String) async throws -> WhatsAppNotificationEvent? { nil }
}
extension WhatsAppWorker {
  public func activateNotification(token: String) async throws -> WhatsAppNotificationEvent? {
    guard let repository else { return nil }
    return try await repository.activateNotification(token: token)
  }
}
