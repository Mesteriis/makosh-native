import Combine
import Foundation
import MakoshWhatsApp

/// Presentation ownership only. SQL, preparation and protocol commands are
/// delegated to the existing service; a late completion keeps its old context.
@MainActor final class WhatsAppComposerModel: ObservableObject {
  @Published var photoDrafts: [WhatsAppPhotoDraft] = []
  @Published var admittedDraft: WhatsAppComposeAdmission?
  @Published var text = "" { didSet { if !text.utf8.elementsEqual(oldValue.utf8) { changed() } } }
  @Published var attachments: [WhatsAppPreparedFile] = [] { didSet { if attachments != oldValue { changed() } } }
  @Published var reply: WhatsAppMessage? { didSet { if !restoring { restoredReplyID=nil };if reply != oldValue { changed() } } }
  @Published private(set) var sending = false
  @Published private(set) var preparing = false
  @Published private(set) var outbox: [WhatsAppOutgoing] = []
  @Published private(set) var outboxHasMore = false
  @Published private(set) var outboxLoading = false
  private var outboxCursor: WhatsAppOutgoingCursor?
  @Published var error: String?
  @Published private(set) var notice: String?
  @Published private(set) var shownBatch: WhatsAppBatchSnapshot?
  @Published private(set) var batchBusy = false
  @Published var showPhotoEditor=false
  @Published var photoMode: WhatsAppPhotoMode = .standard { didSet { if photoMode != oldValue { changed() } } }
  lazy var photoEditor=WhatsAppPhotoEditorModel(worker:worker)
  var restoring=false
  var itemOrder: [WhatsAppComposeItem]=[]
  var restoredReplyID: String?
  var debounce: Task<Void,Never>?
  var dirtyContexts=Set<Context>()
  var knownAbsent=Set<Context>()
  var admittedRevisions: [Context:UInt64]=[:]
  var persistence: [Context:Task<WhatsAppComposeDraft,Error>]=[:]
  struct Context: Hashable {
    let account: UUID
    let chat: Data
    var chatID: String { String(decoding: chat, as: UTF8.self) }
  }
  struct Draft: Equatable {
    var text: String
    var attachments: [WhatsAppPreparedFile]
    var reply: WhatsAppMessage?
    var photos: [WhatsAppPhotoDraft] = []
    var order: [WhatsAppComposeItem] = []
    var restoredReplyID: String? = nil
    var photoMode: WhatsAppPhotoMode = .standard
  }
  lazy var voice = WhatsAppVoiceRecordingModel(
    worker: worker, synthetic: synthetic,
    prepared: { [weak self] file in self?.acceptPrepared(file) })
  let worker: any WhatsAppServing
  private let synthetic: Bool
  var context: Context?
  var generation: UInt64 = 0, revision: UInt64 = 0
  var drafts: [Context: Draft] = [:]
  var pending = Set<Context>()
  private var preparations: [Context: (UUID, Task<Void, Never>)] = [:]
  var canResume: Bool { !synthetic && !sending }
  init(worker: any WhatsAppServing, synthetic: Bool) {
    self.worker = worker
    self.synthetic = synthetic
  }
  func setContext(account: UUID?, chat: String?) {
    let next = account.flatMap { account in
      chat.map { Context(account: account, chat: Data($0.utf8)) }
    }
    guard next != context else { return }
    if let context {
      let old=snapshotDraft();drafts[context]=old
      if dirtyContexts.contains(context),!pending.contains(context) { enqueuePersist(old,source:context) }
    }
    debounce?.cancel();restoring=true
    defer { restoring=false }
    voice.cancel()
    generation &+= 1
    context = next
    let saved = next.flatMap { drafts[$0] }
    text = saved?.text ?? ""
    attachments = saved?.attachments ?? []
    reply = saved?.reply
    photoDrafts=saved?.photos ?? [];itemOrder=saved?.order ?? [];restoredReplyID=saved?.restoredReplyID;photoMode=saved?.photoMode ?? .standard
    admittedDraft=nil
    photoEditor.cancel();showPhotoEditor=false
    error = nil
    notice = nil
    outbox = []
    outboxCursor = nil
    outboxHasMore = false
    outboxLoading = false
    shownBatch = nil
    batchBusy = false
    updatePreparing()
    updateSending()
  }
  private func updateSending() { sending = context.map { pending.contains($0) } ?? false }
  private func updatePreparing() { preparing = context.map { preparations[$0] != nil } ?? false }
  func matchesContext(account: UUID?, chat: String?) -> Bool {
    guard let account, let chat else { return false }
    return context?.account == account && context?.chat == Data(chat.utf8)
  }
  func send(expectedAccount: UUID?, expectedChat: String?) async {
    guard let expectedAccount, let expectedChat, context?.account == expectedAccount,
      context?.chat == Data(expectedChat.utf8)
    else { return }
    await send()
  }
  func draftText(account: UUID?, chat: String?) -> String {
    guard let account, let chat else { return "" }
    let source = Context(account: account, chat: Data(chat.utf8))
    return context == source ? text : drafts[source]?.text ?? ""
  }
  func setDraftText(_ value: String, account: UUID?, chat: String?) {
    guard let account, let chat else { return }
    let source = Context(account: account, chat: Data(chat.utf8))
    if context == source {
      text = value
    } else {
      var old = drafts[source] ?? .init(text: "", attachments: [], reply: nil)
      old.text = value
      drafts[source] = old
      dirtyContexts.insert(source);enqueuePersist(old,source:source)
    }
  }
  func send() async {
    guard let source = context, !pending.contains(source), preparations[source] == nil, !text.isEmpty || !attachments.isEmpty || !photoDrafts.isEmpty
    else { return }
    guard attachments.count + photoDrafts.count <= 10, Set(attachments.map(\.id)).count == attachments.count,
      attachments.allSatisfy({ (0...100 * 1024 * 1024).contains($0.size) }) else {
      error = "Не больше 10 файлов по 100 МиБ каждый."
      return
    }
    let snapshot = snapshotDraft()
    let capturedRevision = revision
    let exportMode=photoMode
    let token = generation
    pending.insert(source)
    var receivedAdmission=false
    updateSending()
    error = nil
    notice = nil
    defer {
      pending.remove(source)
      updateSending()
      if dirtyContexts.contains(source) {
        let latest=context == source ? snapshotDraft():drafts[source]
        if let latest,latest != snapshot || receivedAdmission { enqueuePersist(latest,source:source) }
      }
    }
    do {
      let persisted=try await persist(snapshot,source:source)
      if (context == source && revision == capturedRevision) || (context != source && drafts[source] == snapshot) { dirtyContexts.remove(source) }
      var photoFiles: [UUID:WhatsAppPreparedFile]=[:]
      let currentPhotos=snapshot.photos.isEmpty ? [] : try await worker.photoDrafts(accountID:source.account,chat:source.chatID)
      for photo in snapshot.photos {
        guard let current=currentPhotos.first(where: { $0.id == photo.id }),current.revision == photo.revision,current.recipe == photo.recipe else { throw WhatsAppFailure.invalid }
        photoFiles[photo.id]=try await worker.renderPhoto(id:photo.id,accountID:source.account,chat:source.chatID,expectedRevision:current.revision,mode:exportMode)
      }
      let prepared=try ordered(snapshot).map { item -> WhatsAppPreparedFile in
        switch item {
        case .file(let id): guard let file=snapshot.attachments.first(where: { $0.id == id }) else { throw WhatsAppFailure.invalid };return file
        case .photo(let id): guard let file=photoFiles[id] else { throw WhatsAppFailure.invalid };return file
        }
      }
      let content = WhatsAppOutgoingContent(text: snapshot.text, replyTo: snapshot.reply?.id ?? snapshot.restoredReplyID, files: prepared.map(\.id),composeRevision:persisted.revision)
      let acceptedNotice: String?
      if prepared.count > 1 {
        let batch = try await worker.sendBatch(accountID: source.account, chat: source.chatID, content: content)
        acceptedNotice = batch.issue?.explanation ?? (synthetic ? "Синтетическая очередь · файлы не отправлены" : nil)
      } else {
        let result = try await worker.send(accountID: source.account, chat: source.chatID, content: content)
        acceptedNotice = result.state == .prepared && synthetic ? "Синтетическая очередь · сообщение не отправлено" : nil
      }
      receivedAdmission=true;admittedRevisions[source]=max(admittedRevisions[source] ?? 0,persisted.revision)
      if context == source, generation == token, revision == capturedRevision {
        restoring=true
        text = "";attachments = [];reply = nil;photoDrafts=[];itemOrder=[];restoredReplyID=nil
        drafts[source] = nil;dirtyContexts.remove(source);restoring=false
        let admitted=try await worker.composeDraft(accountID:source.account,chat:source.chatID)?.admitted
        if context == source,generation == token, text.isEmpty,attachments.isEmpty,photoDrafts.isEmpty { admittedDraft=admitted }
      }
      if context != source,drafts[source] == snapshot { drafts[source]=nil;dirtyContexts.remove(source) }
      if context == source, generation == token {
        notice = acceptedNotice
        await refreshOutbox()
      }
    } catch {
      if context == source, generation == token {
        self.error =
          (error as? LocalizedError)?.errorDescription
          ?? "Не удалось завершить отправку. Проверьте очередь; не повторяйте сообщение с неизвестным результатом."
      }
    }
  }
  func attach(_ file: URL, kind: String, mime: String, targetAccount: UUID?, targetChat: String?)
    async
  {
    await prepareSelection([file], asFiles: false, targetAccount: targetAccount, targetChat: targetChat, override: (kind, mime))
  }
  func attach(_ files: [URL], asFiles: Bool, targetAccount: UUID?, targetChat: String?) async {
    await prepareSelection(files, asFiles: asFiles, targetAccount: targetAccount, targetChat: targetChat, override: nil)
  }
  private func prepareSelection(_ files: [URL], asFiles: Bool, targetAccount: UUID?, targetChat: String?, override: (String, String)?) async {
    guard let targetAccount, let targetChat else { return }
    let source = Context(account: targetAccount, chat: Data(targetChat.utf8))
    guard preparations[source] == nil else { return }
    let token = generation, owner = UUID()
    let existing = context == source ? attachments : drafts[source]?.attachments ?? []
    let existingPhotos=context == source ? photoDrafts : drafts[source]?.photos ?? []
    guard existing.count+existingPhotos.count+files.count <= 10 else { error="Можно прикрепить не больше 10 файлов.";return }
    if context == source { error = nil; notice = nil }
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      do {
        let candidates = try await WhatsAppAttachmentSelection.inspect(files, asFiles: asFiles, existing: existing)
        for candidate in candidates {
          try Task.checkCancellation()
          if !asFiles,override == nil,candidate.kind == "image" {
            let photo=try await worker.capturePhoto(accountID:source.account,chat:source.chatID,file:candidate.file)
            try Task.checkCancellation()
            acceptPhoto(photo,source:source,generation:token)
          } else {
            let value = try await worker.prepareFile(accountID: source.account, chat: source.chatID,
              file: candidate.file, kind: override?.0 ?? candidate.kind, mime: override?.1 ?? candidate.mime)
            try Task.checkCancellation();acceptPrepared(value, source: source, generation: token)
          }
        }
      } catch {
        if context == source, generation == token {
          if error is CancellationError { notice = "Подготовка остановлена. Готовые файлы сохранены в черновике." }
          else { self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось подготовить файл." }
        }
      }
    }
    preparations[source] = (owner, task); updatePreparing()
    await task.value
    if preparations[source]?.0 == owner { preparations[source] = nil }
    updatePreparing()
    if context == source,generation == token { await saveDraft() }
    else if let old=drafts[source] { _=try? await persist(old,source:source) }
  }
  func moveAttachment(from: Int, to: Int) {
    guard attachments.indices.contains(from), attachments.indices.contains(to), from != to else { return }
    let file = attachments.remove(at: from); attachments.insert(file, at: to)
    let positions=itemOrder.indices.filter { if case .file = itemOrder[$0] { return true };return false }
    for (i,position) in positions.enumerated() where i < attachments.count { itemOrder[position] = .file(attachments[i].id) }
    changed()
  }
  func removeAttachment(id: UUID) { itemOrder.removeAll { $0 == .file(id) };attachments.removeAll { $0.id == id } }
  func cancelPreparation() { if let context { preparations[context]?.1.cancel() } }
  func recordVoice(expectedAccount: UUID?, expectedChat: String?) {
    guard let source = context, source.account == expectedAccount, source.chatID == expectedChat
    else { return }
    voice.start(account: source.account, chat: source.chatID)
  }
  private func acceptPrepared(_ file: WhatsAppPreparedFile) {
    let source = Context(account: file.accountID, chat: Data(file.chat.utf8))
    acceptPrepared(file, source: source, generation: generation)
  }
  private func acceptPrepared(_ file: WhatsAppPreparedFile, source: Context, generation token: UInt64) {
    guard file.accountID == source.account, Data(file.chat.utf8) == source.chat else { return }
    let existing = context == source && generation == token ? attachments : drafts[source]?.attachments ?? []
    guard !existing.contains(where: { $0.id == file.id }) else { return }
    guard existing.count < 10, (0...100 * 1024 * 1024).contains(file.size) else {
      if context == source { error = "Не больше 10 файлов по 100 МиБ каждый. Подготовленный файл сохранён." }
      return
    }
    if context == source, generation == token {
      itemOrder.append(.file(file.id));attachments.append(file)
    } else {
      var old = drafts[source] ?? .init(text: "", attachments: [], reply: nil)
      old.order.append(.file(file.id));old.attachments.append(file)
      drafts[source] = old;dirtyContexts.insert(source)
    }
  }
  func quote(_ message: WhatsAppMessage, expectedAccount: UUID) {
    guard context?.account == expectedAccount, context?.chat == Data(message.chat.utf8) else {
      return
    }
    reply = message
  }
  func refreshOutbox() async { await loadOutbox(more: false) }
  func moreOutbox() async { if outboxHasMore { await loadOutbox(more: true) } }
  private func loadOutbox(more: Bool) async {
    guard let source = context, !outboxLoading else { return }
    let token = generation
    outboxLoading = true
    defer { if generation == token { outboxLoading = false } }
    do {
      let page = try await worker.outgoingPage(accountID: source.account, before: more ? outboxCursor : nil)
      if context == source, generation == token {
        outbox = more ? outbox + page.values : page.values
        outboxCursor = page.next
        outboxHasMore = page.next != nil
      }
    } catch { if context == source, generation == token { self.error = error.localizedDescription } }
  }
  func resume(_ value: WhatsAppOutgoing, copy: Bool = false) async {
    guard let source = context, source.account == value.accountID, !pending.contains(source) else {
      return
    }
    let token = generation
    pending.insert(source)
    updateSending()
    defer {
      pending.remove(source)
      updateSending()
    }
    do {
      if copy {
        _ = try await worker.copyOutgoing(accountID: value.accountID, id: value.id)
      } else {
        _ = try await worker.resumeOutgoing(accountID: value.accountID, id: value.id)
      }
      if generation == token { await refreshOutbox() }
    } catch { if generation == token { self.error = error.localizedDescription } }
  }
  func resolve(_ value: WhatsAppOutgoing, sent: Bool) async {
    guard let source = context, source.account == value.accountID else { return }
    let token = generation
    do {
      try await worker.resolveOutgoing(accountID: value.accountID, id: value.id, sent: sent)
      if context == source, generation == token { await refreshOutbox(); await refreshShownBatch() }
    } catch {
      if context == source, generation == token {
        self.error =
          (error as? LocalizedError)?.errorDescription
          ?? "Не удалось разрешить результат. Действующая отправка не изменена."
      }
    }
  }
  func showBatch(_ value: WhatsAppOutgoing) async {
    guard let id = value.batchID, let source = context, source.account == value.accountID else { return }
    let token = generation
    do {
      let snapshot = try await worker.batch(accountID: source.account, id: id)
      if context == source, generation == token { shownBatch = snapshot }
    } catch { if context == source, generation == token { self.error = error.localizedDescription } }
  }
  func dismissBatch() { shownBatch = nil }
  func refreshShownBatch() async {
    guard let batch = shownBatch, let source = context, batch.batch.accountID == source.account else { return }
    let token = generation
    do {
      let value = try await worker.batch(accountID: source.account, id: batch.batch.id)
      if context == source, generation == token, shownBatch?.batch.id == batch.batch.id { shownBatch = value }
    } catch { if context == source, generation == token { self.error = error.localizedDescription } }
  }
  func continueShownBatch() async {
    guard let batch = shownBatch, let source = context, source.account == batch.batch.accountID, !batchBusy, !synthetic else { return }
    let token = generation
    batchBusy = true
    defer { if generation == token { batchBusy = false } }
    do {
      let result = try await worker.continueBatch(accountID: source.account, id: batch.batch.id)
      if context == source, generation == token, shownBatch?.batch.id == batch.batch.id {
        shownBatch = result; await refreshOutbox()
      }
    } catch { if context == source, generation == token { self.error = error.localizedDescription } }
  }
}
