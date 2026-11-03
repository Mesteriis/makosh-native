import AppKit
import Combine
import Foundation
import ImageIO
import MakoshCore
import MakoshWhatsApp

/// Window-owned conductor; only bounded worker previews are decoded off-main.
@MainActor final class WhatsAppPhotoEditorModel: ObservableObject {
  @Published private(set) var drafts: [WhatsAppPhotoDraft] = []
  @Published private(set) var selectedID: UUID?
  @Published private(set) var preview: WhatsAppPhotoPreview?
  @Published private(set) var image: NSImage?
  @Published private(set) var thumbnails: [UUID: NSImage] = [:]
  @Published private(set) var busy = false
  @Published private(set) var error: String?
  var selectedDraft: WhatsAppPhotoDraft? { drafts.first { $0.id == selectedID } }
  private let worker: any WhatsAppServing
  private(set) var generation: UInt64 = 0
  private var account: UUID?, chat: String?
  init(worker: any WhatsAppServing) { self.worker = worker }
  func open(drafts: [WhatsAppPhotoDraft], accountID: UUID, chat: String) async {
    cancel()
    self.account = accountID
    self.chat = chat
    guard drafts.count <= 10, Set(drafts.map(\.id)).count == drafts.count,
      drafts.allSatisfy({
        $0.accountID == accountID && $0.chat.utf8.elementsEqual(chat.utf8) && $0.sourceReady
      })
    else {
      error = "Не удалось открыть фотографии этого черновика."
      return
    }
    self.drafts = drafts
    selectedID = drafts.first?.id
    await refreshPreview()
  }
  func select(_ id: UUID) async {
    guard !busy, drafts.contains(where: { $0.id == id }) else { return }
    generation &+= 1
    selectedID = id
    await refreshPreview()
  }
  func apply(_ operation: WhatsAppPhotoOperation) async {
    guard let draft = selectedDraft else { return }
    var recipe = draft.recipe
    recipe.operations.append(operation)
    await save(recipe)
  }
  func undo() async {
    guard var recipe = selectedDraft?.recipe, !recipe.operations.isEmpty else { return }
    recipe.operations.removeLast()
    await save(recipe)
  }
  func reset() async { await save(.init()) }
  private func save(_ recipe: WhatsAppPhotoRecipe) async {
    guard !busy, let draft = selectedDraft else { return }
    let token = generation
    busy = true
    error = nil
    do {
      let saved = try await worker.savePhotoRecipe(
        id: draft.id, accountID: draft.accountID, chat: draft.chat,
        expectedRevision: draft.revision, recipe: recipe)
      guard generation == token, selectedDraft == draft, !Task.isCancelled else { return }
      guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
      drafts[index] = saved
      busy = false
      await refreshPreview()
    } catch {
      if generation == token {
        busy = false
        self.error =
          "Правки не сохранены: черновик изменён или хранилище недоступно. Откройте редактор заново."
      }
    }
  }
  private func decode(_ value: WhatsAppPhotoPreview, edge: Int) async throws -> NSImage {
    let cg = try await BackgroundWork.run {
      guard value.encodedPreview.count <= 16 * 1024 * 1024, (1...1600).contains(value.width),
        (1...1600).contains(value.height),
        let src = CGImageSourceCreateWithData(value.encodedPreview as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          src, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      else { throw WhatsAppFailure.invalid }
      return image
    }
    return NSImage(cgImage: cg, size: .init(width: cg.width, height: cg.height))
  }
  private func refreshPreview() async {
    guard let draft = selectedDraft else { return }
    let token = generation
    busy = true
    image = nil
    preview = nil
    error = nil
    defer { if generation == token { busy = false } }
    do {
      let value = try await worker.photoPreview(
        id: draft.id, accountID: draft.accountID, chat: draft.chat, expectedRevision: draft.revision
      )
      let decoded = try await decode(value, edge: 1600)
      let thumb = try await decode(value, edge: 52)
      guard generation == token, selectedDraft == draft, !Task.isCancelled else { return }
      preview = value
      image = decoded
      thumbnails[draft.id] = thumb
      // Unselected photographs retain only tiny thumbnails, never full decoded images.
      for other in drafts where other.id != draft.id && thumbnails[other.id] == nil {
        let otherPreview = try await worker.photoPreview(
          id: other.id, accountID: other.accountID, chat: other.chat,
          expectedRevision: other.revision)
        let thumbnail = try await decode(otherPreview, edge: 52)
        guard generation == token, selectedDraft == draft, !Task.isCancelled else { return }
        thumbnails[other.id] = thumbnail
      }
    } catch {
      if generation == token {
        self.error = "Не удалось получить предпросмотр. Исходник не будет отправлен вместо правок."
      }
    }
  }
  func prepare(mode: WhatsAppPhotoMode) async -> [WhatsAppPreparedFile]? {
    guard !busy, !drafts.isEmpty, let account, let chat else { return nil }
    let token = generation
    let snapshot = drafts
    busy = true
    error = nil
    defer { if generation == token { busy = false } }
    do {
      var files: [WhatsAppPreparedFile] = []
      for draft in snapshot {
        let file = try await worker.renderPhoto(
          id: draft.id, accountID: account, chat: chat, expectedRevision: draft.revision, mode: mode
        )
        guard generation == token, drafts == snapshot, !Task.isCancelled else { return nil }
        files.append(file)
      }
      return files
    } catch {
      if generation == token {
        self.error = "Экспорт не завершён. Фотографии и правки сохранены; отправка не началась."
      }
      return nil
    }
  }
  func remove(_ id: UUID) async {
    guard !busy else { return }
    generation &+= 1
    drafts.removeAll { $0.id == id }
    thumbnails[id] = nil
    if selectedID == id {
      selectedID = drafts.first?.id
      image = nil
      preview = nil
      await refreshPreview()
    }
  }
  func cancel() {
    generation &+= 1
    drafts = []
    selectedID = nil
    preview = nil
    image = nil
    thumbnails = [:]
    busy = false
    error = nil
    account = nil
    chat = nil
  }
}
