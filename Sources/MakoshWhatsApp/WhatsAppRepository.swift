import CryptoKit
import Foundation
import MakoshCore

public actor WhatsAppRepository {
  private let configuration: ContactWorkspaceConfiguration
  private let keyProvider: @Sendable (UUID, Bool) throws -> Data
  private var database: WhatsAppPostgres?
  private var archive: MessageArchiveStore?
  public init(
    configuration: ContactWorkspaceConfiguration,
    keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open
  ) {
    self.configuration = configuration
    self.keyProvider = keyProvider
  }
  func db() throws -> WhatsAppPostgres {
    if let database { return database }
    let database = try WhatsAppPostgres(configuration: configuration, keyProvider: keyProvider)
    self.database = database
    return database
  }
  func retained() throws -> MessageArchiveStore {
    if let archive { return archive }
    let archive = try MessageArchiveStore(
      connectionString: configuration.connectionString,
      schema: configuration.archiveSchema ?? configuration.schema, keyProvider: keyProvider)
    self.archive = archive
    return archive
  }
  public func accounts() throws -> [WhatsAppAccount] { try db().accounts() }
  public func saveAccount(_ account: WhatsAppAccount) throws { try db().saveAccount(account) }
  public func saveChats(_ chats: [WhatsAppChat], accountID: UUID) throws {
    let db = try db()
    guard try db.accounts().contains(where: { $0.id == accountID }) else {
      throw WhatsAppFailure.invalid
    }
    try db.transaction {
      for chat in chats {
        let token = db.token([accountID.uuidString, chat.id])
        _ = try db.query(
          "INSERT INTO \(db.chatsTable) VALUES($1,$2,$3::bigint,$4) ON CONFLICT(token) DO UPDATE SET ts=excluded.ts,ciphertext=excluded.ciphertext",
          [token, accountID.uuidString, String(chat.timestamp), try db.seal(chat, token: token)])
      }
    }
  }
  public func chats(accountID: UUID) throws -> [WhatsAppChat] {
    let db = try db()
    return try db.query(
      "SELECT c.token,c.ciphertext,m.token,m.ciphertext FROM \(db.chatsTable) c LEFT JOIN LATERAL (SELECT token,ciphertext,ts FROM \(db.messagesTable) WHERE chat=c.token ORDER BY ts DESC,token DESC LIMIT 1) m ON TRUE WHERE c.account=$1 ORDER BY GREATEST(c.ts,COALESCE(m.ts,0)) DESC,c.token DESC",
      [accountID.uuidString]
    ).map { row in
      var chat: WhatsAppChat = try db.decode(row[1], token: row[0])
      if !row[2].isEmpty {
        let message: WhatsAppMessage = try db.decode(row[3], token: row[2])
        chat.preview = message.text.isEmpty ? message.kind : message.text
        chat.timestamp = max(chat.timestamp, message.timestamp)
      }
      return chat
    }
  }
  /// No receipt/ack is produced until both permanent archive and projection commit.
  /// Stable source sequence + observed time makes an interrupted transfer idempotent.
  public func ingest(_ entries: [WhatsAppJournalEntry], accountID: UUID) throws {
    guard entries.count <= 100,
      entries.allSatisfy({
        $0.sequence > 0 && !$0.message.chat.isEmpty && !$0.message.id.isEmpty
          && $0.message.text.utf8.count <= 2 * 1024 * 1024
      })
    else { throw WhatsAppFailure.invalid }
    let db = try db()
    guard try db.accounts().contains(where: { $0.id == accountID }) else {
      throw WhatsAppFailure.invalid
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for entry in entries {
      let digest = SHA256.hash(data: try encoder.encode(entry)).map { String(format: "%02x", $0) }
        .joined()
      let receipts = try db.query(
        "SELECT digest FROM \(db.receiptsTable) WHERE account=$1 AND sequence=$2::bigint",
        [accountID.uuidString, String(entry.sequence)])
      if let previous = receipts.first {
        guard previous[0] == digest else { throw WhatsAppFailure.invalid }
        continue
      }
      var message = entry.message
      let event: MessageArchiveEvent =
        message.deleted
        ? .deleted
        : .message(
          .init(
            date: Date(timeIntervalSince1970: TimeInterval(message.timestamp)),
            editedAt: message.edited
              ? Date(timeIntervalSince1970: TimeInterval(entry.observed)) : nil, text: message.text,
            author: message.sender, authorID: message.sender, isOutgoing: message.outgoing,
            attachments: message.details?.resourceID.map { resource in
              [.init(id: resource, kind: message.kind, name: message.details?.name ?? "", size: message.details?.size.flatMap(Int64.init(exactly:)))]
            } ?? []))
      _ = try retained().append([
        .init(
          id: entry.observationID(accountID: accountID),
          identity: .init(
            service: "whatsapp", accountID: accountID.uuidString, conversationID: message.chat,
            messageID: message.id),
          observedAt: Date(timeIntervalSince1970: TimeInterval(entry.observed)),
          source: entry.history ? .history : .update, event: event, sourcePayload: try encoder.encode(entry.message))
      ])
      try db.transaction {
        try recordRejection(accountID: accountID, message: message, db: db)
        if message.kind != "protocol" {
          let token = db.token([accountID.uuidString, message.chat, message.id])
          let chatToken = db.token([accountID.uuidString, message.chat])
          let oldRow = try db.query(
            "SELECT ciphertext FROM \(db.messagesTable) WHERE token=$1 FOR UPDATE", [token]
          ).first
          let old: WhatsAppMessage? = try oldRow.map { try db.decode($0[0], token: token) }
          message.delivery = max(message.delivery ?? 0, old?.delivery ?? 0)
          if let rejection = old?.details?.rejection, message.details?.rejection == nil {
            if message.details == nil { message.details = .init() }
            message.details?.rejection = rejection
          }
          if let receipts = old?.details?.receipts, !receipts.isEmpty {
            if message.details == nil { message.details = .init() }
            for receipt in receipts
            where message.details?.receipts.contains(where: {
              $0.sender == receipt.sender && $0.level >= receipt.level
            }) != true {
              message.details?.receipts.removeAll { $0.sender == receipt.sender }
              message.details?.receipts.append(receipt)
            }
          }
          if old.map({ message.versionOrder >= $0.versionOrder }) ?? true {
            _ = try db.query(
              "INSERT INTO \(db.messagesTable) VALUES($1,$2,$3,$4::bigint,$5) ON CONFLICT(token) DO UPDATE SET ts=excluded.ts,ciphertext=excluded.ciphertext",
              [
                token, accountID.uuidString, chatToken, String(message.timestamp),
                try db.seal(message, token: token),
              ])
          }
          let chat = WhatsAppChat(
            id: message.chat, name: message.chat, timestamp: message.timestamp,
            group: message.chat.hasSuffix("@g.us"))
          _ = try db.query(
            "INSERT INTO \(db.chatsTable) VALUES($1,$2,$3::bigint,$4) ON CONFLICT(token) DO UPDATE SET ts=GREATEST(\(db.chatsTable).ts,excluded.ts)",
            [
              chatToken, accountID.uuidString, String(message.timestamp),
              try db.seal(chat, token: chatToken),
            ])
          try admitNotification(entry, accountID: accountID, firstSeen: old == nil, db: db)
        }
        let versionToken = db.token([accountID.uuidString, "version", String(entry.sequence)])
        _ = try db.query(
          "INSERT INTO \(db.receiptsTable)(account,sequence,digest,ciphertext,chat) VALUES($1,$2::bigint,$3,$4,$5)",
          [
            accountID.uuidString, String(entry.sequence), digest,
            try db.seal(entry, token: versionToken),
            db.token([accountID.uuidString, message.chat]),
          ])
      }
    }
  }
  public func messages(accountID: UUID, chat: String, before: WhatsAppCursor?, limit: Int = 50)
    throws -> [WhatsAppMessage]
  {
    guard (1...100).contains(limit) else { throw WhatsAppFailure.invalid }
    let db = try db()
    var params = [accountID.uuidString, db.token([accountID.uuidString, chat])]
    var predicate = "account=$1 AND chat=$2"
    if let before {
      params.append(String(before.timestamp))
      params.append(before.id)
      predicate += " AND (ts<$3::bigint OR (ts=$3::bigint AND token<$4))"
    }
    return try db.query(
      "SELECT token,ciphertext FROM \(db.messagesTable) WHERE " + predicate
        + " ORDER BY ts DESC,token DESC LIMIT \(limit)", params
    ).map { row in
      var message: WhatsAppMessage = try db.decode(row[1], token: row[0])
      message.pageToken = row[0]
      return message
    }
  }
  public func versions(accountID: UUID, chat: String) throws -> [MessageArchiveRecord] {
    try retained().records(
      service: "whatsapp", accountID: accountID.uuidString, conversationID: chat, before: nil,
      limit: 200)
  }
  public func retainedEntries(accountID: UUID, chat: String, before: Int64? = nil, limit: Int = 50)
    throws -> [WhatsAppJournalEntry]
  {
    guard (1...100).contains(limit) else { throw WhatsAppFailure.invalid }
    let db = try db()
    var params = [accountID.uuidString, db.token([accountID.uuidString, chat])]
    var predicate = "account=$1 AND chat=$2 AND ciphertext IS NOT NULL"
    if let before {
      params.append(String(before))
      predicate += " AND sequence<$3::bigint"
    }
    return try db.query(
      "SELECT sequence,ciphertext FROM \(db.receiptsTable) WHERE \(predicate) ORDER BY sequence DESC LIMIT \(limit)",
      params
    ).map { row in
      guard let sequence = Int64(row[0]) else { throw WhatsAppFailure.storage }
      return try db.decode(
        row[1], token: db.token([accountID.uuidString, "version", String(sequence)]))
    }
  }
}
