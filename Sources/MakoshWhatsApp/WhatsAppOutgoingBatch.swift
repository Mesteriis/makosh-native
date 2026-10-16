import Foundation

public struct WhatsAppOutgoingBatch: Codable, Equatable, Identifiable, Sendable {
  public struct Child: Codable, Equatable, Sendable {
    public let index: Int
    public let outgoingID: UUID, reservedAttemptID: UUID, fileID: UUID
  }
  public let id: UUID, accountID: UUID
  public let chat: String
  public let created: Date
  public let orderedChildren: [Child]
}
public struct WhatsAppBatchSnapshot: Equatable, Sendable {
  public let batch: WhatsAppOutgoingBatch
  public let children: [WhatsAppOutgoing]
  public let files: [WhatsAppPreparedFile]
  public var issue: WhatsAppBatchIssue?
  public init(
    batch: WhatsAppOutgoingBatch, children: [WhatsAppOutgoing], files: [WhatsAppPreparedFile] = [],
    issue: WhatsAppBatchIssue? = nil
  ) {
    self.batch = batch
    self.children = children
    self.files = files
    self.issue = issue
  }
  public var blocked: Bool { children.contains { $0.state != .prepared && $0.state != .sent } }
}
public struct WhatsAppBatchIssue: Equatable, Sendable {
  public enum Reason: Sendable {
    case preparation, connection, uncertain, notSent, rejected, owned, cancelled
  }
  public let childID: UUID?
  public let reason: Reason
  public var explanation: String {
    switch reason {
    case .preparation: "Не удалось открыть очередной файл. Подготовленные элементы сохранены."
    case .connection: "Соединение изменилось. Оставшиеся файлы не отправлены."
    case .uncertain: "Результат неизвестен. Проверьте его у получателя перед продолжением."
    case .notSent: "Ядро не приняло файл. Оставшиеся элементы не отправлены."
    case .rejected: "Сервер отклонил сообщение. Отправка пакета остановлена."
    case .owned: "Этот пакет уже отправляется в другом окне или процессе."
    case .cancelled: "Отправка остановлена. Оставшиеся подготовленные файлы сохранены."
    }
  }
}
public struct WhatsAppBatchLease: Equatable, Sendable {
  public let id: UUID, accountID: UUID
  let nonce: UUID
  let knownFailures: Set<UUID>
  func permitsPrefix(_ child: WhatsAppOutgoing) -> Bool {
    child.state == .sent
      || knownFailures.contains(child.id) && (child.state == .notSent || child.state == .rejected)
  }
}
extension WhatsAppRepository {
  public func prepareOutgoingBatch(accountID: UUID, chat: String, content: WhatsAppOutgoingContent)
    throws -> WhatsAppBatchSnapshot
  {
    try validateOutgoing(chat: chat, content: content)
    guard !content.files.isEmpty, content.action == nil else { throw WhatsAppFailure.invalid }
    let db = try db()
    return try db.transaction {
      guard try db.accounts().contains(where: { $0.id == accountID }) else {
        throw WhatsAppFailure.invalid
      }
      let draft = try checkedCompose(accountID: accountID, chat: chat, content: content, db: db)
      if let admission = draft?.admitted {
        guard case .batch(let id) = admission else { throw WhatsAppFailure.invalid }
        return try readBatchSnapshot(id: id, accountID: accountID, db: db)
      }
      var total: Int64 = 0
      let files = try content.files.map { id -> WhatsAppPreparedFile in
        let file = try preparedFile(id: id, accountID: accountID, chat: chat)
        guard file.size >= 0, file.size <= 100 * 1024 * 1024 else { throw WhatsAppFailure.invalid }
        total += file.size
        guard total <= 1000 * 1024 * 1024 else { throw WhatsAppFailure.invalid }
        return file
      }
      let id = UUID()
      let created = Date()
      let references = files.enumerated().map {
        WhatsAppOutgoingBatch.Child(
          index: $0.offset,
          outgoingID: UUID(), reservedAttemptID: UUID(), fileID: $0.element.id)
      }
      let batch = WhatsAppOutgoingBatch(
        id: id, accountID: accountID, chat: chat, created: created, orderedChildren: references)
      let children = zip(references, files).map { reference, file in
        WhatsAppOutgoing(
          id: reference.outgoingID, accountID: accountID, chat: chat,
          content: .init(
            text: reference.index == 0 ? content.text : "",
            replyTo: reference.index == 0 ? content.replyTo : nil, files: [file.id],
            kind: file.kind,
            mentions: reference.index == 0 ? content.mentions : []), created: created,
          attemptID: reference.reservedAttemptID, state: .prepared, batchID: id)
      }
      for child in children { try storeOutgoing(child, db: db, insert: true) }
      let token = db.token([accountID.uuidString, "batch", id.uuidString])
      _ = try db.query(
        "INSERT INTO \(db.batchesTable) VALUES($1,$2,$3::bigint,$4)",
        [
          token, accountID.uuidString, String(Int64(created.timeIntervalSince1970 * 1000)),
          try db.seal(batch, token: token),
        ])
      if var draft {
        draft.admitted = .batch(id)
        try storeCompose(draft, db: db)
      }
      return .init(batch: batch, children: children, files: files)
    }
  }
  public func batch(id: UUID, accountID: UUID) throws -> WhatsAppBatchSnapshot {
    let db = try db()
    return try db.transaction { try readBatchSnapshot(id: id, accountID: accountID, db: db) }
  }
  public func claimBatch(id: UUID, accountID: UUID, continuing: Bool = false) throws
    -> WhatsAppBatchLease
  {
    let db = try db()
    guard db.batchOwners[id] == nil else { throw WhatsAppFailure.invalid }
    var locked = false
    do {
      let lease = try db.transaction {
        let snapshot = try readBatchSnapshot(id: id, accountID: accountID, db: db)
        if continuing,
          snapshot.children.contains(where: { $0.state == .unknown || $0.state == .dispatching })
        {
          throw WhatsAppFailure.invalid
        }
        guard try lockBatch(id, db: db)
        else { throw WhatsAppFailure.owned }
        locked = true
        return WhatsAppBatchLease(
          id: id, accountID: accountID, nonce: UUID(),
          knownFailures: continuing
            ? Set(
              snapshot.children.filter { $0.state == .notSent || $0.state == .rejected }.map(\.id))
            : [])
      }
      db.batchOwners[id] = lease
      return lease
    } catch {
      if locked { try? unlockBatch(id, db: db) }
      throw error
    }
  }
  public func releaseBatch(_ lease: WhatsAppBatchLease) throws {
    let db = try db()
    guard db.batchOwners[lease.id] == lease else { throw WhatsAppFailure.invalid }
    try unlockBatch(lease.id, db: db)
    db.batchOwners[lease.id] = nil
  }
  func lockBatch(_ id: UUID, db: WhatsAppPostgres) throws -> Bool {
    guard db.batchOwners[id] == nil else { return false }
    return try db.query("SELECT pg_try_advisory_lock(hashtextextended($1,17403))", [id.uuidString])
      .first?.first == "t"
  }
  func unlockBatch(_ id: UUID, db: WhatsAppPostgres) throws {
    guard
      try db.query("SELECT pg_advisory_unlock(hashtextextended($1,17403))", [id.uuidString]).first?
        .first == "t"
    else { throw WhatsAppFailure.storage }
  }
  func batchChildForClaim(
    id: UUID, accountID: UUID, lease: WhatsAppBatchLease, db: WhatsAppPostgres
  ) throws -> WhatsAppOutgoing {
    guard lease.accountID == accountID, db.batchOwners[lease.id] == lease else {
      throw WhatsAppFailure.invalid
    }
    let snapshot = try readBatchSnapshot(id: lease.id, accountID: accountID, db: db)
    guard snapshot.children.allSatisfy({ $0.state == .prepared || lease.permitsPrefix($0) }),
      let index = snapshot.children.firstIndex(where: { $0.id == id }),
      snapshot.children.prefix(index).allSatisfy({ lease.permitsPrefix($0) }),
      snapshot.children[index...].allSatisfy({ $0.state == .prepared })
    else { throw WhatsAppFailure.invalid }
    return snapshot.children[index]
  }
  private func readBatch(id: UUID, accountID: UUID, db: WhatsAppPostgres) throws
    -> WhatsAppOutgoingBatch
  {
    let token = db.token([accountID.uuidString, "batch", id.uuidString])
    guard
      let row = try db.query(
        "SELECT ciphertext FROM \(db.batchesTable) WHERE token=$1 AND account=$2 FOR UPDATE",
        [token, accountID.uuidString]
      ).first
    else { throw WhatsAppFailure.invalid }
    let batch: WhatsAppOutgoingBatch = try db.decode(row[0], token: token)
    let children = batch.orderedChildren
    guard batch.id == id, batch.accountID == accountID, !batch.chat.isEmpty,
      (1...10).contains(children.count),
      children.map(\.index) == Array(0..<children.count),
      Set(children.map(\.outgoingID)).count == children.count,
      Set(children.map(\.reservedAttemptID)).count == children.count,
      Set(children.map(\.fileID)).count == children.count
    else { throw WhatsAppFailure.storage }
    return batch
  }
  private func readBatchSnapshot(id: UUID, accountID: UUID, db: WhatsAppPostgres) throws
    -> WhatsAppBatchSnapshot
  {
    let batch = try readBatch(id: id, accountID: accountID, db: db)
    let children = try batch.orderedChildren.map { reference in
      var child = try readOutgoing(reference.outgoingID, accountID: accountID, db: db)
      guard child.batchID == batch.id, child.chat.utf8.elementsEqual(batch.chat.utf8),
        child.attemptID == reference.reservedAttemptID, child.content.files == [reference.fileID],
        child.content.composeRevision == nil, child.content.action == nil
      else { throw WhatsAppFailure.storage }
      if child.state == .dispatching, !db.outgoingOwners.contains(child.id) {
        child.state = .unknown
      }
      return child
    }
    let files = try batch.orderedChildren.map {
      try preparedFile(id: $0.fileID, accountID: accountID, chat: batch.chat)
    }
    return .init(batch: batch, children: children, files: files)
  }
}
