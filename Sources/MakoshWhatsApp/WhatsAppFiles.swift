import Foundation
import MakoshCore

public struct WhatsAppPreparedFile: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let accountID: UUID
  public let chat: String
  public let name: String
  public let kind: String
  public let mime: String
  public let size: Int64
  public var record: ArchiveFileRecord?
  public var voice: Bool?
  public var seconds: Int64?
  var identity: MessageArchiveIdentity {
    .init(
      service: "whatsapp", accountID: accountID.uuidString, conversationID: chat,
      messageID: "preparation-" + id.uuidString.lowercased())
  }
  var attachment: MessageArchiveAttachment {
    .init(id: id.uuidString.lowercased(), kind: kind, name: name, size: size)
  }
}
public struct WhatsAppFileLease: Sendable {
  public let url: URL
  let directory: URL
  public func remove() { try? FileManager.default.removeItem(at: directory) }
}
extension WhatsAppRepository {
  func savePreparedFile(_ file: WhatsAppPreparedFile) throws {
    let db = try db()
    guard try db.accounts().contains(where: { $0.id == file.accountID }) else {
      throw WhatsAppFailure.invalid
    }
    let token = db.token([file.accountID.uuidString, "file", file.id.uuidString])
    _ = try db.query(
      "INSERT INTO \(db.filesTable) VALUES($1,$2,$3) ON CONFLICT(token) DO UPDATE SET ciphertext=excluded.ciphertext",
      [token, file.accountID.uuidString, try db.seal(file, token: token)])
  }
  func preparedFileIfExists(id: UUID, accountID: UUID, chat: String) throws -> WhatsAppPreparedFile? {
    let db = try db(), token=db.token([accountID.uuidString,"file",id.uuidString])
    guard try !db.query("SELECT token FROM \(db.filesTable) WHERE token=$1 AND account=$2",[token,accountID.uuidString]).isEmpty else { return nil }
    return try preparedFile(id:id,accountID:accountID,chat:chat)
  }
  func reservePreparedFile(_ file: WhatsAppPreparedFile) throws -> WhatsAppPreparedFile {
    let db=try db()
    return try db.transaction {
      if let prior=try preparedFileIfExists(id:file.id,accountID:file.accountID,chat:file.chat) { return prior }
      guard try db.accounts().contains(where: { $0.id == file.accountID }) else { throw WhatsAppFailure.invalid }
      let token=db.token([file.accountID.uuidString,"file",file.id.uuidString])
      _=try db.query("INSERT INTO \(db.filesTable) VALUES($1,$2,$3) ON CONFLICT(token) DO NOTHING",[token,file.accountID.uuidString,try db.seal(file,token:token)])
      return try preparedFile(id:file.id,accountID:file.accountID,chat:file.chat)
    }
  }
  func preparedFile(id: UUID, accountID: UUID, chat: String) throws -> WhatsAppPreparedFile {
    let db = try db()
    let token = db.token([accountID.uuidString, "file", id.uuidString])
    guard
      let row = try db.query(
        "SELECT ciphertext FROM \(db.filesTable) WHERE token=$1 AND account=$2",
        [token, accountID.uuidString]
      ).first
    else { throw WhatsAppFailure.invalid }
    let file: WhatsAppPreparedFile = try db.decode(row[0], token: token)
    guard file.id == id, file.accountID == accountID, file.chat == chat else {
      throw WhatsAppFailure.invalid
    }
    return file
  }
}
/// File/crypto/SQL/S3 work stays on this concrete service actor. IPC transfers
/// private temporary leases, never a whole file encoded in a JSON frame.
public actor WhatsAppFiles {
  private let configuration: ContactWorkspaceConfiguration
  private let storageFile: URL
  private let spool: URL
  let repository: WhatsAppRepository
  private let keyProvider: @Sendable (UUID, Bool) throws -> Data
  private var archive: MessageArchiveStore?
  private var files: ArchiveFileRepository?
  public init(
    configuration: ContactWorkspaceConfiguration, storageFile: URL, spool: URL,
    repository: WhatsAppRepository,
    keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open
  ) {
    self.configuration = configuration
    self.storageFile = storageFile
    self.spool = spool
    self.repository = repository
    self.keyProvider = keyProvider
  }
  private func archiveStore() throws -> MessageArchiveStore {
    if let archive { return archive }
    let value = try MessageArchiveStore(
      connectionString: configuration.connectionString,
      schema: configuration.archiveSchema ?? configuration.schema, keyProvider: keyProvider)
    archive = value
    return value
  }
  private func fileStore() throws -> ArchiveFileRepository {
    if let files { return files }
    let value = try ArchiveFileRepository(
      connectionString: configuration.connectionString,
      schema: configuration.archiveSchema ?? configuration.schema,
      configuration: S3ConfigurationFile.read(storageFile), spoolDirectory: spool,
      keyProvider: keyProvider)
    files = value
    return value
  }
  private func identity(_ account: UUID, _ chat: String) -> MessageArchiveIdentity {
    .init(
      service: "whatsapp", accountID: account.uuidString, conversationID: chat, messageID: "policy")
  }
  public static func defaultSaving(chat: String) -> Bool {
    !chat.hasSuffix("@g.us") && !chat.hasSuffix("@broadcast") && !chat.hasSuffix("@newsletter")
  }
  public func saving(accountID: UUID, chat: String) throws -> Bool {
    guard !chat.isEmpty else { throw WhatsAppFailure.invalid }
    return try archiveStore().conversationFileSavingEnabled(
      identity: identity(accountID, chat), defaultEnabled: Self.defaultSaving(chat: chat))
  }
  public func setSaving(accountID: UUID, chat: String, enabled: Bool) throws {
    guard !chat.isEmpty else { throw WhatsAppFailure.invalid }
    try archiveStore().setConversationFileSavingEnabled(
      identity: identity(accountID, chat), enabled: enabled)
  }
  private func incomingIdentity(_ account: UUID, _ message: WhatsAppMessage) throws -> (
    MessageArchiveIdentity, String
  ) {
    guard !message.chat.isEmpty, !message.id.isEmpty, let resource = message.details?.resourceID,
      resource.utf8.count == 64,
      resource.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw WhatsAppFailure.invalid }
    return (
      .init(
        service: "whatsapp", accountID: account.uuidString, conversationID: message.chat,
        messageID: message.id), resource
    )
  }
  public func archived(accountID: UUID, message: WhatsAppMessage) async throws
    -> [ArchiveFileRecord]
  {
    let (identity, resource) = try incomingIdentity(accountID, message)
    return try await fileStore().files(identity: identity, attachmentID: resource).filter {
      $0.state == .stored
    }
  }
  public func archiveIncoming(file: URL, accountID: UUID, message: WhatsAppMessage) async throws
    -> ArchiveFileRecord?
  {
    let (identity, resource) = try incomingIdentity(accountID, message)
    guard try saving(accountID: accountID, chat: message.chat) else { return nil }
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    guard let size = attrs[.size] as? NSNumber, size.int64Value >= 0,
      size.int64Value <= 100 * 1024 * 1024
    else { throw WhatsAppFailure.invalid }
    let job = try await repository.reserveIncomingFile(accountID: accountID, message: message)
    let store = try fileStore()
    if let recovered = try await store.recoverConversationCapture(
      id: job.id, identity: identity, attachmentID: resource)
    {
      return recovered
    }
    let capture = try ArchiveFileCapture(file: file, byteCount: size.int64Value)
    let hash = try capture.plaintextSHA256()
    if let prior = try await store.files(identity: identity, attachmentID: resource).first(where: {
      $0.state == .stored && $0.plaintextSHA256 == hash
    }) {
      return prior
    }
    let attachment = MessageArchiveAttachment(
      id: resource, kind: message.kind, name: message.details?.name ?? "", size: size.int64Value)
    return try await store.captureConversationFile(
      capture, identity: identity, attachment: attachment,
      defaultEnabled: Self.defaultSaving(chat: message.chat), reservedID: job.id)
  }
  func openArchived(_ record: ArchiveFileRecord) async throws -> WhatsAppFileLease {
    let lease = try makeLease(name: record.attachment.name)
    do {
      try await fileStore().export(record, to: lease.url)
      return lease
    } catch {
      lease.remove()
      throw error
    }
  }
  public func prepare(file: URL, accountID: UUID, chat: String, kind: String, mime: String, reservedID: UUID? = nil, localOnly: Bool = false)
    async throws -> WhatsAppPreparedFile
  {
    guard !chat.isEmpty, chat.utf8.count <= 1024,
      ["image", "video", "document", "audio", "sticker"].contains(kind), mime.utf8.count <= 128,
      file.lastPathComponent.utf8.count <= 512
    else { throw WhatsAppFailure.invalid }
    let access = file.startAccessingSecurityScopedResource()
    defer { if access { file.stopAccessingSecurityScopedResource() } }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard let count = attributes[.size] as? NSNumber, count.int64Value >= 0,
      count.int64Value <= 100 * 1024 * 1024
    else { throw WhatsAppFailure.invalid }
    let capture = try ArchiveFileCapture(file: file, byteCount: count.int64Value)
    var value = WhatsAppPreparedFile(
      id: reservedID ?? UUID(), accountID: accountID, chat: chat, name: file.lastPathComponent, kind: kind,
      mime: mime, size: count.int64Value)
    // Reserve before capture. A retry recovers the same envelope without PUT or promotion.
    let prior=try await repository.reservePreparedFile(value)
    guard prior.name == value.name,prior.kind == kind,prior.mime == mime,prior.size == value.size else { throw WhatsAppFailure.invalid }
    value=prior
    let store=try fileStore()
    if value.record == nil {
      value.record=try await store.recoverOutgoingCapture(id:value.id,identity:value.identity,attachmentID:value.attachment.id,uploadPending:false)
    }
    if let receipt=value.record {
      guard receipt.plaintextSHA256 == (try capture.plaintextSHA256()),!localOnly || receipt.state == .local else { throw WhatsAppFailure.invalid }
    } else if localOnly {
      value.record=try await store.captureLocalPreparation(capture,identity:value.identity,attachment:value.attachment,reservedID:value.id)
    } else {
      value.record=try await store.capture(capture,identity:value.identity,attachment:value.attachment,
        defaultEnabled:Self.defaultSaving(chat:chat),reservedID:value.id)
    }
    try await repository.savePreparedFile(value)
    return value
  }
  public func prepared(id: UUID, accountID: UUID, chat: String) async throws -> WhatsAppPreparedFile {
    let value=try await repository.preparedFile(id:id,accountID:accountID,chat:chat)
    guard let recovered=try await recoverRecord(value) else { throw WhatsAppFailure.storage }
    return recovered
  }
  /// Nil proves no capture was admitted. Corruption/missing keys never become nil.
  func recoveredPrepared(id: UUID,accountID: UUID,chat: String) async throws -> WhatsAppPreparedFile? {
    guard let value=try await repository.preparedFileIfExists(id:id,accountID:accountID,chat:chat) else { return nil }
    return try await recoverRecord(value)
  }
  private func recoverRecord(_ input: WhatsAppPreparedFile) async throws -> WhatsAppPreparedFile? {
    var value=input
    _=try saving(accountID:value.accountID,chat:value.chat)
    if value.record == nil {
      guard let record=try await fileStore().recoverOutgoingCapture(id:value.id,identity:value.identity,attachmentID:value.attachment.id,uploadPending:false) else { return nil }
      value.record=record;try await repository.savePreparedFile(value)
    }
    return value
  }
  public func open(_ value: WhatsAppPreparedFile) async throws -> WhatsAppFileLease {
    let saved = try await prepared(id: value.id, accountID: value.accountID, chat: value.chat)
    guard saved == value, let record = value.record else { throw WhatsAppFailure.invalid }
    let lease = try makeLease(name: value.name)
    do {
      try await fileStore().export(record, to: lease.url)
      return lease
    } catch {
      lease.remove()
      throw error
    }
  }
  func makeLease(name: String) throws -> WhatsAppFileLease {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "makosh-wa-lease-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let name = URL(fileURLWithPath: name).lastPathComponent
    return .init(
      url: directory.appendingPathComponent(name.isEmpty ? "file" : name), directory: directory)
  }
}
