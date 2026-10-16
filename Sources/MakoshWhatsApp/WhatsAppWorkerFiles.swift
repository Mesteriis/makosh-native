import Foundation
import MakoshCore

extension WhatsAppRepository {
  func message(accountID: UUID, chat: String, id: String) throws -> WhatsAppMessage {
    let db = try db()
    let token = db.token([accountID.uuidString, chat, id])
    guard
      let row = try db.query(
        "SELECT ciphertext FROM \(db.messagesTable) WHERE token=$1 AND account=$2",
        [token, accountID.uuidString]
      ).first
    else { throw WhatsAppFailure.invalid }
    return try db.decode(row[0], token: token)
  }
}
extension WhatsAppServing {
  public func prepareFile(accountID: UUID, chat: String, file: URL, kind: String, mime: String)
    async throws -> WhatsAppPreparedFile
  { throw WhatsAppFailure.unavailable }
  public func savingFiles(accountID: UUID, chat: String) async throws -> Bool {
    throw WhatsAppFailure.unavailable
  }
  public func setSavingFiles(accountID: UUID, chat: String, enabled: Bool) async throws {
    throw WhatsAppFailure.unavailable
  }
  public func downloadVersion(
    accountID: UUID, chat: String, id: String, resource: String, kind: String, name: String
  ) async throws -> WhatsAppFileLease { throw WhatsAppFailure.unavailable }
  public func download(accountID: UUID, chat: String, id: String) async throws -> WhatsAppFileLease
  { throw WhatsAppFailure.unavailable }
}
extension WhatsAppWorker {
  private func requireAccount(_ id: UUID) async throws {
    guard let repository, try await repository.accounts().contains(where: { $0.id == id }) else {
      throw WhatsAppFailure.invalid
    }
  }
  public func prepareFile(accountID: UUID, chat: String, file: URL, kind: String, mime: String)
    async throws -> WhatsAppPreparedFile
  {
    try await requireAccount(accountID)
    guard let files else { throw WhatsAppFailure.storage }
    return try await files.prepare(
      file: file, accountID: accountID, chat: chat, kind: kind, mime: mime)
  }
  public func savingFiles(accountID: UUID, chat: String) async throws -> Bool {
    try await requireAccount(accountID)
    guard let files else { throw WhatsAppFailure.storage }
    return try await files.saving(accountID: accountID, chat: chat)
  }
  public func setSavingFiles(accountID: UUID, chat: String, enabled: Bool) async throws {
    try await requireAccount(accountID)
    guard let files else { throw WhatsAppFailure.storage }
    try await files.setSaving(accountID: accountID, chat: chat, enabled: enabled)
  }
  public func download(accountID: UUID, chat: String, id: String) async throws -> WhatsAppFileLease
  {
    try await requireAccount(accountID)
    guard let files, let repository else { throw WhatsAppFailure.storage }
    let message = try await repository.message(accountID: accountID, chat: chat, id: id)
    return try await downloadMessage(accountID: accountID, message: message)
  }
  public func downloadVersion(
    accountID: UUID, chat: String, id: String, resource: String, kind: String, name: String
  ) async throws -> WhatsAppFileLease {
    try await requireAccount(accountID)
    guard let repository else { throw WhatsAppFailure.storage }
    var before: Int64?
    var found = false
    repeat {
      let rows = try await repository.archivePage(accountID: accountID, chat: chat, before: before)
      found = rows.contains { row in
        guard row.observation.identity.messageID.utf8.elementsEqual(id.utf8),
          case .message(let content) = row.observation.event
        else { return false }
        return content.attachments.contains { $0.id.utf8.elementsEqual(resource.utf8) }
      }
      before = rows.count == 100 ? rows.last?.sequence : nil
      try Task.checkCancellation()
    } while !found && before != nil
    guard found else { throw WhatsAppFailure.invalid }
    var message = try await repository.message(accountID: accountID, chat: chat, id: id)
    message.kind = kind
    message.details = .init()
    message.details?.resourceID = resource
    message.details?.name = name
    return try await downloadMessage(accountID: accountID, message: message)
  }
  func downloadMessage(accountID: UUID, message: WhatsAppMessage, expectedGeneration: UInt64? = nil) async throws -> WhatsAppFileLease
  {
    if let expectedGeneration { guard revisions[accountID] == expectedGeneration else { throw CancellationError() } }
    guard let files, let repository else { throw WhatsAppFailure.storage }
    let chat = message.chat
    let id = message.id
    guard ["image", "video", "audio", "sticker", "document"].contains(message.kind) else {
      throw WhatsAppFailure.invalid
    }
    if message.outgoing, let resource = message.details?.resourceID,
      try await repository.outgoingResourceMatches(
        accountID: accountID, chat: chat, stanza: message.stanza, resource: resource),
      let id = try await repository.outgoingFileIDs(
        accountID: accountID, chat: chat, stanza: message.stanza
      ).first
    {
      return try await files.open(files.prepared(id: id, accountID: accountID, chat: chat))
    }
    if let record = try await files.archived(accountID: accountID, message: message).first {
      return try await files.openArchived(record)
    }
    if let expectedGeneration { guard revisions[accountID] == expectedGeneration, !Task.isCancelled else { throw CancellationError() } }
    guard let session = sessions[accountID], !synthetic else { throw WhatsAppFailure.closed }
    let generation = revisions[accountID]
    let lease = try await files.makeLease(name: message.details?.name ?? "WhatsApp-\(message.kind)")
    do {
      var action = WhatsAppAction(.download, target: id)
      action.path = lease.url.path
      action.value = message.details?.resourceID ?? ""
      _ = try await session.perform(chat: chat, action: action)
      guard revisions[accountID] == generation else { throw CancellationError() }
      _ = try await files.archiveIncoming(file: lease.url, accountID: accountID, message: message)
      return lease
    } catch {
      lease.remove()
      throw error
    }
  }
}
