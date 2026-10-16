import Foundation

public enum WhatsAppComposeItem: Codable, Equatable, Hashable, Sendable {
  case file(UUID)
  case photo(UUID)
  public var id: UUID {
    switch self {
    case .file(let id), .photo(let id): id
    }
  }
}
public enum WhatsAppComposeAdmission: Codable, Equatable, Sendable {
  case outgoing(UUID)
  case batch(UUID)
}
public struct WhatsAppComposeDraft: Codable, Equatable, Sendable {
  public let accountID: UUID
  public let chat: String
  public var revision: UInt64 = 0
  public var text: String, replyTo: String?
  public var orderedItems: [WhatsAppComposeItem]
  public var mentions: [String]
  public var admitted: WhatsAppComposeAdmission?
  public var photoMode: WhatsAppPhotoMode?
  public init(
    accountID: UUID, chat: String, text: String, replyTo: String? = nil,
    orderedItems: [WhatsAppComposeItem] = [], mentions: [String] = []
  ) {
    self.accountID = accountID
    self.chat = chat
    self.text = text
    self.replyTo = replyTo
    self.orderedItems = orderedItems
    self.mentions = mentions
  }
}
extension WhatsAppRepository {
  public func saveComposeDraft(_ draft: WhatsAppComposeDraft, expectedRevision: UInt64?) throws
    -> WhatsAppComposeDraft
  {
    try validateCompose(draft)
    guard draft.admitted == nil else { throw WhatsAppFailure.invalid }
    let db = try db()
    return try db.transaction {
      guard try db.accounts().contains(where: { $0.id == draft.accountID }) else {
        throw WhatsAppFailure.invalid
      }
      let current = try readCompose(accountID: draft.accountID, chat: draft.chat, db: db)
      if let expectedRevision {
        guard expectedRevision < UInt64.max, draft.revision == expectedRevision,
          current?.revision == expectedRevision
        else { throw WhatsAppFailure.invalid }
      } else {
        guard current == nil, draft.revision == 0 else { throw WhatsAppFailure.invalid }
      }
      var value = draft
      value.revision = (expectedRevision ?? 0) + 1
      try storeCompose(value, db: db, insert: current == nil)
      return value
    }
  }
  public func composeDraft(accountID: UUID, chat: String) throws -> WhatsAppComposeDraft? {
    try readCompose(accountID: accountID, chat: chat, db: db())
  }
  func checkedCompose(
    accountID: UUID, chat: String, content: WhatsAppOutgoingContent, db: WhatsAppPostgres
  ) throws -> WhatsAppComposeDraft? {
    guard let revision = content.composeRevision else { return nil }
    guard let draft = try readCompose(accountID: accountID, chat: chat, db: db),
      draft.revision == revision,
      content.action == nil, draft.text.utf8.elementsEqual(content.text.utf8),
      optionalTextMatches(draft.replyTo, content.replyTo),
      draft.mentions.count == content.mentions.count,
      zip(draft.mentions, content.mentions).allSatisfy({ $0.utf8.elementsEqual($1.utf8) })
    else { throw WhatsAppFailure.invalid }
    let files = try draft.orderedItems.map { item -> UUID in
      switch item {
      case .file(let id): return id
      case .photo(let id):
        let photo = try readPhoto(id: id, accountID: accountID, chat: chat, db: db)
        guard photo.sourceReady, photo.exportedRevision == photo.revision,
          draft.photoMode == nil || photo.mode == draft.photoMode, let file = photo.exportedFileID
        else { throw WhatsAppFailure.invalid }
        let receipt = try preparedFile(id: file, accountID: accountID, chat: chat)
        guard receipt.kind == "image", receipt.record != nil else { throw WhatsAppFailure.invalid }
        return file
      }
    }
    guard files == content.files else { throw WhatsAppFailure.invalid }
    return draft
  }
  func storeCompose(_ draft: WhatsAppComposeDraft, db: WhatsAppPostgres, insert: Bool = false)
    throws
  {
    let token = db.token([draft.accountID.uuidString, "compose", draft.chat])
    if insert {
      _ = try db.query(
        "INSERT INTO \(db.composeTable) VALUES($1,$2,$3)",
        [token, draft.accountID.uuidString, try db.seal(draft, token: token)])
    } else {
      _ = try db.query(
        "UPDATE \(db.composeTable) SET ciphertext=$3 WHERE token=$1 AND account=$2",
        [token, draft.accountID.uuidString, try db.seal(draft, token: token)])
    }
  }
  private func readCompose(accountID: UUID, chat: String, db: WhatsAppPostgres) throws
    -> WhatsAppComposeDraft?
  {
    let token = db.token([accountID.uuidString, "compose", chat])
    guard
      let row = try db.query(
        "SELECT ciphertext FROM \(db.composeTable) WHERE token=$1 AND account=$2 FOR UPDATE",
        [token, accountID.uuidString]
      ).first
    else { return nil }
    let draft: WhatsAppComposeDraft = try db.decode(row[0], token: token)
    guard draft.accountID == accountID, draft.chat.utf8.elementsEqual(chat.utf8), draft.revision > 0
    else { throw WhatsAppFailure.storage }
    try validateCompose(draft)
    return draft
  }
  private func validateCompose(_ draft: WhatsAppComposeDraft) throws {
    guard !draft.chat.isEmpty, draft.chat.utf8.count <= 1024, !draft.chat.utf8.contains(0),
      draft.text.utf8.count <= 65536, draft.orderedItems.count <= 10,
      Set(draft.orderedItems.map(\.id)).count == draft.orderedItems.count,
      draft.replyTo.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? true,
      draft.mentions.count <= 100,
      draft.mentions.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 })
    else { throw WhatsAppFailure.invalid }
  }
  private func optionalTextMatches(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case (.some(let a), .some(let b)): a.utf8.elementsEqual(b.utf8)
    default: false
    }
  }
}
