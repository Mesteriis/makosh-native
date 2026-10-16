import Foundation

extension WhatsAppServing {
  public func capturePhoto(accountID: UUID, chat: String, file: URL) async throws
    -> WhatsAppPhotoDraft
  { throw WhatsAppFailure.unavailable }
  public func savePhotoRecipe(
    id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64, recipe: WhatsAppPhotoRecipe
  ) async throws -> WhatsAppPhotoDraft { throw WhatsAppFailure.unavailable }
  public func photoPreview(id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64)
    async throws -> WhatsAppPhotoPreview
  { throw WhatsAppFailure.unavailable }
  public func renderPhoto(
    id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64, mode: WhatsAppPhotoMode
  ) async throws -> WhatsAppPreparedFile { throw WhatsAppFailure.unavailable }
  public func photoDrafts(accountID: UUID, chat: String) async throws -> [WhatsAppPhotoDraft] {
    throw WhatsAppFailure.unavailable
  }
  public func saveComposeDraft(_ draft: WhatsAppComposeDraft, expectedRevision: UInt64?)
    async throws -> WhatsAppComposeDraft
  { throw WhatsAppFailure.unavailable }
  public func composeDraft(accountID: UUID, chat: String) async throws -> WhatsAppComposeDraft? {
    throw WhatsAppFailure.unavailable
  }
  public func preparedFile(accountID: UUID, chat: String, id: UUID) async throws
    -> WhatsAppPreparedFile
  { throw WhatsAppFailure.unavailable }
}
extension WhatsAppWorker {
  private func photoService(accountID: UUID) async throws -> WhatsAppPhotoPreparation {
    guard let repository, try await repository.accounts().contains(where: { $0.id == accountID }),
      let files
    else { throw WhatsAppFailure.storage }
    if photos == nil { photos = WhatsAppPhotoPreparation(repository: repository, files: files) }
    return photos!
  }
  public func capturePhoto(accountID: UUID, chat: String, file: URL) async throws
    -> WhatsAppPhotoDraft
  {
    try await photoService(accountID: accountID).capture(
      file: file, accountID: accountID, chat: chat)
  }
  public func savePhotoRecipe(
    id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64, recipe: WhatsAppPhotoRecipe
  ) async throws -> WhatsAppPhotoDraft {
    try await photoService(accountID: accountID).saveRecipe(
      id: id, accountID: accountID, chat: chat, expectedRevision: expectedRevision, recipe: recipe)
  }
  public func photoPreview(id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64)
    async throws -> WhatsAppPhotoPreview
  {
    try await photoService(accountID: accountID).preview(
      id: id, accountID: accountID, chat: chat, expectedRevision: expectedRevision)
  }
  public func renderPhoto(
    id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64, mode: WhatsAppPhotoMode
  ) async throws -> WhatsAppPreparedFile {
    try await photoService(accountID: accountID).render(
      id: id, accountID: accountID, chat: chat, expectedRevision: expectedRevision, mode: mode)
  }
  public func photoDrafts(accountID: UUID, chat: String) async throws -> [WhatsAppPhotoDraft] {
    try await photoService(accountID: accountID).drafts(accountID: accountID, chat: chat)
  }
  public func saveComposeDraft(_ draft: WhatsAppComposeDraft, expectedRevision: UInt64?)
    async throws -> WhatsAppComposeDraft
  {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.saveComposeDraft(draft, expectedRevision: expectedRevision)
  }
  public func composeDraft(accountID: UUID, chat: String) async throws -> WhatsAppComposeDraft? {
    guard let repository else { throw WhatsAppFailure.storage }
    return try await repository.composeDraft(accountID: accountID, chat: chat)
  }
  public func preparedFile(accountID: UUID, chat: String, id: UUID) async throws
    -> WhatsAppPreparedFile
  {
    guard let files else { throw WhatsAppFailure.storage }
    return try await files.prepared(id: id, accountID: accountID, chat: chat)
  }
}
