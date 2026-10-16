import Foundation
import MakoshWhatsApp

extension WhatsAppComposerModel {
  var orderedItems: [WhatsAppComposeItem] { ordered(snapshotDraft()) }
  func moveItem(from: Int, to: Int) {
    var items = orderedItems
    guard items.indices.contains(from), items.indices.contains(to), from != to else { return }
    let item = items.remove(at: from)
    items.insert(item, at: to)
    itemOrder = items
    attachments = items.compactMap { item in
      guard case .file(let id) = item else { return nil }
      return attachments.first { $0.id == id }
    }
    photoDrafts = items.compactMap { item in
      guard case .photo(let id) = item else { return nil }
      return photoDrafts.first { $0.id == id }
    }
    changed()
  }
  func flushDrafts() async {
    debounce?.cancel()
    await saveDraft()
    for task in Array(persistence.values) { _ = try? await task.value }
  }
  func snapshotDraft() -> Draft {
    .init(
      text: text, attachments: attachments, reply: reply, photos: photoDrafts, order: itemOrder,
      restoredReplyID: restoredReplyID, photoMode: photoMode)
  }
  func ordered(_ draft: Draft) -> [WhatsAppComposeItem] {
    let available = Set(
      draft.attachments.map { WhatsAppComposeItem.file($0.id) } + draft.photos.map { .photo($0.id) }
    )
    var items = draft.order.filter { available.contains($0) }
    for item in draft.attachments.map({ WhatsAppComposeItem.file($0.id) })
      + draft.photos.map({ .photo($0.id) }) where !items.contains(item)
    { items.append(item) }
    return items
  }
  func changed() {
    revision &+= 1
    guard !restoring else { return }
    admittedDraft = nil
    if let context { dirtyContexts.insert(context) }
    debounce?.cancel()
    debounce = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      await self.saveDraft()
    }
  }
  func persist(_ snapshot: Draft, source: Context) async throws -> WhatsAppComposeDraft {
    try await enqueuePersist(snapshot, source: source).value
  }
  @discardableResult func enqueuePersist(_ snapshot: Draft, source: Context) -> Task<
    WhatsAppComposeDraft, Error
  > {
    let previous = persistence[source]
    let wasAbsent = knownAbsent.contains(source)
    let consumed = admittedRevisions[source]
    let worker = worker
    let items = ordered(snapshot)
    let task = Task<WhatsAppComposeDraft, Error> {
      let base: WhatsAppComposeDraft?
      if let previous {
        base = try await previous.value
      } else if wasAbsent {
        base = nil
      } else {
        // Initial editing may race restoration. Never rebind an unobserved stored draft.
        guard try await worker.composeDraft(accountID: source.account, chat: source.chatID) == nil
        else { throw WhatsAppFailure.invalid }
        base = nil
      }
      var draft = WhatsAppComposeDraft(
        accountID: source.account, chat: source.chatID, text: snapshot.text,
        replyTo: snapshot.reply?.id ?? snapshot.restoredReplyID, orderedItems: items)
      draft.photoMode = snapshot.photos.isEmpty ? nil : snapshot.photoMode
      if let base {
        draft.revision = base.revision
        if base.admitted == nil, base.revision != consumed, base.text == draft.text,
          base.replyTo == draft.replyTo,
          base.orderedItems == draft.orderedItems, base.mentions == draft.mentions,
          base.photoMode == draft.photoMode
        {
          return base
        }
      }
      return try await worker.saveComposeDraft(draft, expectedRevision: base?.revision)
    }
    persistence[source] = task
    knownAbsent.remove(source)
    return task
  }
  func saveDraft() async {
    guard let source = context, !restoring, !pending.contains(source),
      dirtyContexts.contains(source)
    else { return }
    let token = generation
    let capturedRevision = revision
    let snapshot = snapshotDraft()
    do {
      _ = try await persist(snapshot, source: source)
      if context == source, generation == token, revision == capturedRevision {
        dirtyContexts.remove(source)
      }
    } catch {
      if context == source, generation == token {
        self.error =
          "Черновик не сохранён: конфликт версии или хранилище недоступно. Откройте диалог заново."
      }
    }
  }
  func restoreDraft() async {
    guard let source = context else { return }
    if dirtyContexts.contains(source) {
      await saveDraft()
      return
    }
    let token = generation
    let capturedRevision = revision
    do {
      if let previous = persistence[source] { _ = try? await previous.value }
      let saved = try await worker.composeDraft(accountID: source.account, chat: source.chatID)
      guard context == source, generation == token, revision == capturedRevision, !Task.isCancelled
      else { return }
      guard let saved else {
        persistence[source] = nil
        knownAbsent.insert(source)
        return
      }
      persistence[source] = Task { saved }
      knownAbsent.remove(source)
      if let admitted = saved.admitted {
        admittedRevisions[source] = max(admittedRevisions[source] ?? 0, saved.revision)
        restoring = true
        text = ""
        attachments = []
        photoDrafts = []
        itemOrder = []
        reply = nil
        restoredReplyID = nil
        restoring = false
        admittedDraft = admitted
        await refreshOutbox()
        return
      }
      let hasPhotos = saved.orderedItems.contains {
        if case .photo = $0 { return true }
        return false
      }
      let allPhotos =
        hasPhotos
        ? try await worker.photoDrafts(accountID: source.account, chat: source.chatID) : []
      var files: [WhatsAppPreparedFile] = []
      var photos: [WhatsAppPhotoDraft] = []
      for item in saved.orderedItems {
        switch item {
        case .file(let id):
          files.append(
            try await worker.preparedFile(accountID: source.account, chat: source.chatID, id: id))
        case .photo(let id):
          guard let photo = allPhotos.first(where: { $0.id == id && $0.sourceReady }) else {
            throw WhatsAppFailure.storage
          }
          photos.append(photo)
        }
      }
      guard context == source, generation == token, revision == capturedRevision, !Task.isCancelled
      else { return }
      restoring = true
      text = saved.text
      reply = nil
      restoredReplyID = saved.replyTo
      attachments = files
      photoDrafts = photos
      itemOrder = saved.orderedItems
      photoMode = saved.photoMode ?? .standard
      restoring = false
      drafts[source] = snapshotDraft()
    } catch {
      if context == source, generation == token {
        self.error = "Не удалось восстановить черновик. Сохранённые данные не изменены."
      }
    }
  }
  /// Explicit read-only reload is the user's choice to replace unsaved UI edits.
  func reloadSavedDraft() async {
    guard let source = context, !pending.contains(source), !preparing else { return }
    let token = generation
    let capturedRevision = revision
    debounce?.cancel()
    if let task = persistence[source] { _ = try? await task.value }
    guard context == source, generation == token, revision == capturedRevision else { return }
    dirtyContexts.remove(source)
    persistence[source] = nil
    knownAbsent.remove(source)
    error = nil
    await restoreDraft()
  }
  func acceptPhoto(_ photo: WhatsAppPhotoDraft, source: Context, generation token: UInt64) {
    guard photo.accountID == source.account, Data(photo.chat.utf8) == source.chat else { return }
    if context == source, generation == token {
      guard attachments.count + photoDrafts.count < 10 else { return }
      photoDrafts.append(photo)
      itemOrder.append(.photo(photo.id))
      changed()
    } else {
      var old = drafts[source] ?? .init(text: "", attachments: [], reply: nil)
      guard old.attachments.count + old.photos.count < 10 else { return }
      old.photos.append(photo)
      old.order.append(.photo(photo.id))
      drafts[source] = old
      dirtyContexts.insert(source)
      enqueuePersist(old, source: source)
    }
  }
  func editPhotos() async {
    guard let source = context, !photoDrafts.isEmpty, !sending, !preparing else { return }
    let token = generation
    do {
      let all = try await worker.photoDrafts(accountID: source.account, chat: source.chatID)
      let ids = Set(photoDrafts.map(\.id))
      let current = all.filter { ids.contains($0.id) }
      guard current.count == ids.count, context == source, generation == token else {
        throw WhatsAppFailure.invalid
      }
      photoDrafts = photoDrafts.compactMap { old in current.first { $0.id == old.id } }
      showPhotoEditor = true
      await photoEditor.open(drafts: photoDrafts, accountID: source.account, chat: source.chatID)
    } catch {
      if context == source, generation == token {
        self.error = "Не удалось открыть сохранённые фотографии."
      }
    }
  }
  func finishPhotoEditor(send: Bool) async {
    guard let source = context, showPhotoEditor, !send || !photoEditor.busy else { return }
    let token = generation
    let current = photoEditor.drafts
    guard
      current.allSatisfy({ $0.accountID == source.account && Data($0.chat.utf8) == source.chat })
    else { return }
    // Removing from this explicit editor updates only this compose selection.
    photoDrafts = current
    let ids = Set(current.map(\.id))
    itemOrder.removeAll {
      if case .photo(let id) = $0 { return !ids.contains(id) }
      return false
    }
    changed()
    let capturedRevision = revision
    let mode = photoMode
    if !send {
      // Revoke before any persistence await: a pending export must never admit a send.
      showPhotoEditor = false
      photoEditor.cancel()
      await saveDraft()
      return
    }
    let editorGeneration = photoEditor.generation
    await saveDraft()
    guard context == source, generation == token, showPhotoEditor, photoEditor.generation == editorGeneration else { return }
    if send, revision != capturedRevision || photoMode != mode {
      error = "Черновик изменён во время подготовки. Проверьте его и отправьте снова."
      return
    }
    if send {
      guard await photoEditor.prepare(mode: mode) != nil else { return }
      guard context == source, generation == token, showPhotoEditor, photoEditor.generation == editorGeneration else { return }
      guard revision == capturedRevision, photoMode == mode else {
        error = "Черновик изменён во время подготовки. Проверьте его и отправьте снова."
        return
      }
    }
    showPhotoEditor = false
    photoEditor.cancel()
    if send { await self.send() }
  }
  func removePhoto(id: UUID) {
    photoDrafts.removeAll { $0.id == id }
    itemOrder.removeAll { $0 == .photo(id) }
    changed()
  }
  func clearReply() {
    reply = nil
    restoredReplyID = nil
    changed()
  }
}
