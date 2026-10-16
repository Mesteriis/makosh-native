import Foundation
import MakoshCore

extension WhatsAppRepository {
  func insertPhoto(_ draft: WhatsAppPhotoDraft) throws {
    let db = try db()
    guard try db.accounts().contains(where: { $0.id == draft.accountID }) else {
      throw WhatsAppFailure.invalid
    }
    try draft.recipe.validate()
    let token = db.token([draft.accountID.uuidString, "photo", draft.id.uuidString])
    _ = try db.query(
      "INSERT INTO \(db.photosTable) VALUES($1,$2,$3)",
      [token, draft.accountID.uuidString, try db.seal(draft, token: token)])
  }
  func readPhoto(id: UUID, accountID: UUID, chat: String, db: WhatsAppPostgres) throws
    -> WhatsAppPhotoDraft
  {
    let token = db.token([accountID.uuidString, "photo", id.uuidString])
    guard
      let row = try db.query(
        "SELECT ciphertext FROM \(db.photosTable) WHERE token=$1 AND account=$2 FOR UPDATE",
        [token, accountID.uuidString]
      ).first
    else { throw WhatsAppFailure.invalid }
    let draft: WhatsAppPhotoDraft = try db.decode(row[0], token: token)
    guard draft.id == id, draft.accountID == accountID, draft.chat.utf8.elementsEqual(chat.utf8),
      draft.revision > 0
    else { throw WhatsAppFailure.storage }
    try draft.recipe.validate()
    return draft
  }
  func photo(id: UUID, accountID: UUID, chat: String) throws -> WhatsAppPhotoDraft {
    try readPhoto(id: id, accountID: accountID, chat: chat, db: db())
  }
  func updatePhoto(
    id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64,
    update: @Sendable (inout WhatsAppPhotoDraft) throws -> Void
  ) throws -> WhatsAppPhotoDraft {
    let db = try db()
    return try db.transaction {
      var draft = try readPhoto(id: id, accountID: accountID, chat: chat, db: db)
      guard draft.revision == expectedRevision else { throw WhatsAppFailure.invalid }
      try update(&draft)
      try draft.recipe.validate()
      let token = db.token([accountID.uuidString, "photo", id.uuidString])
      _ = try db.query(
        "UPDATE \(db.photosTable) SET ciphertext=$3 WHERE token=$1 AND account=$2",
        [token, accountID.uuidString, try db.seal(draft, token: token)])
      return draft
    }
  }
  func photoDrafts(accountID: UUID, chat: String) throws -> [WhatsAppPhotoDraft] {
    let db = try db()
    return try db.query(
      "SELECT token,ciphertext FROM \(db.photosTable) WHERE account=$1 ORDER BY token",
      [accountID.uuidString]
    ).compactMap { row in
      let draft: WhatsAppPhotoDraft = try db.decode(row[1], token: row[0])
      guard draft.accountID == accountID else { throw WhatsAppFailure.storage }
      return draft.chat.utf8.elementsEqual(chat.utf8) ? draft : nil
    }
  }
}

/// Owns one bounded image operation at a time; encrypted source/receipts use the
/// existing file vault. PG contains only scoped recipe metadata and references.
public actor WhatsAppPhotoPreparation {
  public typealias Renderer =
    @Sendable (URL, WhatsAppPhotoRecipe, WhatsAppPhotoMode) async throws ->
    WhatsAppPhotoRenderResult
  private let repository: WhatsAppRepository, files: WhatsAppFiles
  private let renderer: Renderer
  private var rendering = false
  public init(repository: WhatsAppRepository, files: WhatsAppFiles, renderer: Renderer? = nil) {
    self.repository = repository
    self.files = files
    self.renderer =
      renderer ?? { source, recipe, mode in
        try await BackgroundWork.run {
          try WhatsAppPhotoRenderer.render(source: source, recipe: recipe, mode: mode)
        }
      }
  }
  public func capture(file: URL, accountID: UUID, chat: String) async throws -> WhatsAppPhotoDraft {
    guard !chat.isEmpty, chat.utf8.count <= 1024 else { throw WhatsAppFailure.invalid }
    let draft = WhatsAppPhotoDraft(id: UUID(), accountID: accountID, sourceID: UUID(), chat: chat)
    try await repository.insertPhoto(draft)
    _ = try await files.prepare(
      file: file, accountID: accountID, chat: chat, kind: "document",
      mime: "application/octet-stream", reservedID: draft.sourceID, localOnly: true)
    return try await finalizeSource(draft)
  }
  private func finalizeSource(_ draft: WhatsAppPhotoDraft) async throws -> WhatsAppPhotoDraft {
    do {
      let source = try await files.prepared(
        id: draft.sourceID, accountID: draft.accountID, chat: draft.chat)
      guard source.record?.state == .local else { throw WhatsAppFailure.invalid }
      let lease = try await files.open(source)
      defer { lease.remove() }
      let dimensions = try await BackgroundWork.run {
        try WhatsAppPhotoRenderer.dimensions(source: lease.url)
      }
      return try await repository.updatePhoto(
        id: draft.id, accountID: draft.accountID, chat: draft.chat, expectedRevision: draft.revision
      ) {
        $0.sourceReady = true
        $0.width = dimensions.0
        $0.height = dimensions.1
      }
    } catch WhatsAppFailure.invalid {
      _ = try await repository.updatePhoto(
        id: draft.id, accountID: draft.accountID, chat: draft.chat, expectedRevision: draft.revision
      ) { $0.sourceFailed = true }
      throw WhatsAppFailure.invalid
    }
  }
  public func saveRecipe(
    id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64, recipe: WhatsAppPhotoRecipe
  ) async throws -> WhatsAppPhotoDraft {
    try recipe.validate()
    guard expectedRevision < UInt64.max else { throw WhatsAppFailure.invalid }
    return try await repository.updatePhoto(
      id: id, accountID: accountID, chat: chat, expectedRevision: expectedRevision
    ) {
      guard $0.sourceReady else { throw WhatsAppFailure.storage }
      $0.recipe = recipe
      $0.revision += 1
      $0.exportedFileID = nil
      $0.exportedRevision = nil
      $0.mode = nil
    }
  }
  private func checked(id: UUID, accountID: UUID, chat: String, revision: UInt64) async throws
    -> WhatsAppPhotoDraft
  {
    let draft = try await repository.photo(id: id, accountID: accountID, chat: chat)
    guard draft.sourceReady, draft.revision == revision else { throw WhatsAppFailure.invalid }
    try Task.checkCancellation()
    return draft
  }
  private func image(_ draft: WhatsAppPhotoDraft, mode: WhatsAppPhotoMode) async throws
    -> WhatsAppPhotoRenderResult
  {
    let source = try await files.prepared(
      id: draft.sourceID, accountID: draft.accountID, chat: draft.chat)
    let lease = try await files.open(source)
    defer { lease.remove() }
    let result = try await renderer(lease.url, draft.recipe, mode)
    _ = try await checked(
      id: draft.id, accountID: draft.accountID, chat: draft.chat, revision: draft.revision)
    return result
  }
  public func preview(id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64)
    async throws -> WhatsAppPhotoPreview
  {
    guard !rendering else { throw WhatsAppFailure.invalid }
    rendering = true
    defer { rendering = false }
    let draft = try await checked(
      id: id, accountID: accountID, chat: chat, revision: expectedRevision)
    let result = try await image(draft, mode: .standard)
    return .init(encodedPreview: result.finalJPEG, width: result.width, height: result.height)
  }
  public func render(
    id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64, mode: WhatsAppPhotoMode
  ) async throws -> WhatsAppPreparedFile {
    guard !rendering else { throw WhatsAppFailure.invalid }
    rendering = true
    defer { rendering = false }
    var draft = try await checked(
      id: id, accountID: accountID, chat: chat, revision: expectedRevision)
    if draft.exportedRevision == expectedRevision, draft.mode == mode,
      let id = draft.exportedFileID,
      let prepared = try await files.recoveredPrepared(id: id, accountID: accountID, chat: chat)
    {
      let current = try await checked(
        id: draft.id, accountID: accountID, chat: chat, revision: expectedRevision)
      guard current.exportedFileID == id, current.mode == mode else {
        throw WhatsAppFailure.invalid
      }
      return prepared
    }
    let result = try await image(draft, mode: mode)
    // Reserve one stable ID in SQL, before any derivative capture. Concurrent
    // windows use this receipt; a different recipe/mode revokes late results.
    draft = try await repository.updatePhoto(
      id: id, accountID: accountID, chat: chat, expectedRevision: expectedRevision
    ) {
      if $0.exportedRevision != expectedRevision || $0.mode != mode || $0.exportedFileID == nil {
        $0.exportedFileID = UUID()
        $0.exportedRevision = expectedRevision
        $0.mode = mode
      }
    }
    guard let exportID = draft.exportedFileID else { throw WhatsAppFailure.storage }
    let lease = try await files.makeLease(name: "edited.jpg")
    defer { lease.remove() }
    try result.finalJPEG.write(to: lease.url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lease.url.path)
    let before = try await checked(
      id: id, accountID: accountID, chat: chat, revision: expectedRevision)
    guard before.exportedFileID == exportID, before.mode == mode else {
      throw WhatsAppFailure.invalid
    }
    let prepared = try await files.prepare(
      file: lease.url, accountID: accountID, chat: chat, kind: "image", mime: "image/jpeg",
      reservedID: exportID)
    let current = try await checked(
      id: id, accountID: accountID, chat: chat, revision: expectedRevision)
    guard current.exportedFileID == exportID, current.mode == mode else {
      throw WhatsAppFailure.invalid
    }
    return prepared
  }
  public func drafts(accountID: UUID, chat: String) async throws -> [WhatsAppPhotoDraft] {
    var drafts = try await repository.photoDrafts(accountID: accountID, chat: chat)
    for index in drafts.indices
    where !drafts[index].sourceReady && drafts[index].sourceFailed != true {
      let draft = drafts[index]
      // No metadata means capture was never admitted; never recreate its source.
      guard
        try await repository.preparedFileIfExists(
          id: draft.sourceID, accountID: accountID, chat: chat) != nil
      else { continue }
      do { drafts[index] = try await finalizeSource(draft) } catch WhatsAppFailure.invalid {
        drafts[index] = try await repository.photo(id: draft.id, accountID: accountID, chat: chat)
      }
    }
    return drafts
  }
}
