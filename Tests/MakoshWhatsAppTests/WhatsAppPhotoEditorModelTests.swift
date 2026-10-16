import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

@MainActor final class WhatsAppPhotoEditorModelTests: XCTestCase {
  func testComposerCancelDuringExportPreventsAdmissionAndKeepsEdits() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let service = PhotoEditorFixtureService(fixture: f)
    let model = WhatsAppComposerModel(worker: service, synthetic: true)
    model.setContext(account: f.account, chat: "peer@lid")
    model.text = "keep caption"
    await model.attach([source], asFiles: false, targetAccount: f.account, targetChat: "peer@lid")
    await model.editPhotos()
    await model.photoEditor.apply(.rotate90)
    await service.suspendExport()
    let sending = Task { await model.finishPhotoEditor(send: true) }
    for _ in 0..<200 where !(await service.waiting) { try await Task.sleep(for: .milliseconds(2)) }
    let held = await service.waiting
    XCTAssertTrue(held)
    await model.finishPhotoEditor(send: false)
    XCTAssertFalse(model.showPhotoEditor)
    await service.release()
    await sending.value
    let rows = try await f.repository.outgoing(accountID: f.account)
    XCTAssertTrue(rows.isEmpty, "Cancelled export must not admit a message")
    XCTAssertEqual(model.text, "keep caption")
    XCTAssertEqual(model.photoDrafts.count, 1)
    await model.editPhotos()
    XCTAssertEqual(model.photoEditor.selectedDraft?.recipe.operations, [.rotate90])
    await model.finishPhotoEditor(send: false)
  }
  func testUndoRestoresCropRotateAndMarks() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let draft = try await f.photo.capture(file: source, accountID: f.account, chat: "peer@lid")
    let worker = PhotoEditorFixtureService(fixture: f)
    let model = WhatsAppPhotoEditorModel(worker: worker)
    await model.open(drafts: [draft], accountID: f.account, chat: draft.chat)
    await model.apply(.rotate90)
    await model.apply(.crop(.init(x: 0, y: 0, width: 0.5, height: 1)))
    await model.apply(
      .mark(.pen, [.init(x: 0, y: 0), .init(x: 1, y: 1)], .init(r: 1, g: 0, b: 0, a: 1), 0.01))
    XCTAssertEqual(model.selectedDraft?.recipe.operations.count, 3)
    await model.undo()
    XCTAssertEqual(model.selectedDraft?.recipe.operations.count, 2)
    await model.undo()
    XCTAssertEqual(model.selectedDraft?.recipe.operations, [.rotate90])
    await model.reset()
    XCTAssertEqual(model.selectedDraft?.recipe.operations, [])
    XCTAssertNotNil(model.preview)
  }
  func testCancelNeverSendsAndKeepsExistingDraft() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let draft = try await f.photo.capture(file: source, accountID: f.account, chat: "peer@lid")
    let worker = PhotoEditorFixtureService(fixture: f)
    let model = WhatsAppPhotoEditorModel(worker: PhotoEditorFixtureService(fixture: f))
    await model.open(drafts: [draft], accountID: f.account, chat: draft.chat)
    await model.apply(.rotate90)
    model.cancel()
    let saved = try await worker.photoDrafts(accountID: f.account, chat: draft.chat)
    XCTAssertEqual(saved.first?.recipe.operations, [.rotate90])
    XCTAssertNil(model.preview)
    let rows = try await f.repository.outgoing(accountID: f.account)
    XCTAssertTrue(rows.isEmpty)
  }
  func testLatePreviewAndExportRejectChangedAccountChatRecipe() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let draft = try await f.photo.capture(file: source, accountID: f.account, chat: "peer@lid")
    let service = PhotoEditorFixtureService(fixture: f)
    let model = WhatsAppPhotoEditorModel(worker: service)
    await service.suspendPreview()
    let open = Task { await model.open(drafts: [draft], accountID: f.account, chat: draft.chat) }
    for _ in 0..<200 where !(await service.waiting) { try await Task.sleep(for: .milliseconds(2)) }
    let previewWaiting = await service.waiting
    XCTAssertTrue(previewWaiting)
    model.cancel()
    await service.release()
    await open.value
    XCTAssertNil(model.preview)
    XCTAssertNil(model.selectedDraft)
    await model.open(drafts: [draft], accountID: f.account, chat: draft.chat)
    await service.suspendExport()
    let exported = Task { await model.prepare(mode: .standard) }
    for _ in 0..<200 where !(await service.waiting) { try await Task.sleep(for: .milliseconds(2)) }
    let exportWaiting = await service.waiting
    XCTAssertTrue(exportWaiting)
    await model.open(drafts: [], accountID: UUID(), chat: "other@lid")
    await service.release()
    let result = await exported.value
    XCTAssertNil(result)
    XCTAssertNil(model.selectedDraft)
  }
}
actor PhotoEditorFixtureService: WhatsAppServing {
  let f: WhatsAppPhotoRecoveryTests.Fixture
  var failNextAdmission = false
  func failAdmissionOnce() { failNextAdmission = true }
  var pausePreview = false, pauseExport = false, pauseSave = false
  var continuation: CheckedContinuation<Void, Never>?
  var waiting: Bool { continuation != nil }
  init(fixture: WhatsAppPhotoRecoveryTests.Fixture) { f = fixture }
  func suspendSave() { pauseSave = true }
  func suspendPreview() { pausePreview = true }
  func suspendExport() { pauseExport = true }
  func release() {
    continuation?.resume()
    continuation = nil
    pausePreview = false
    pauseExport = false
    pauseSave = false
  }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    .init(accountID: accountID, status: .init(), chats: [])
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) -> [WhatsAppMessage] { [] }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func shutdown() {}
  func capturePhoto(accountID: UUID, chat: String, file: URL) async throws -> WhatsAppPhotoDraft {
    try await f.photo.capture(file: file, accountID: accountID, chat: chat)
  }
  func savePhotoRecipe(
    id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64, recipe: WhatsAppPhotoRecipe
  ) async throws -> WhatsAppPhotoDraft {
    try await f.photo.saveRecipe(
      id: id, accountID: accountID, chat: chat, expectedRevision: expectedRevision, recipe: recipe)
  }
  func photoPreview(id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64) async throws
    -> WhatsAppPhotoPreview
  {
    if pausePreview { await withCheckedContinuation { continuation = $0 } }
    return try await f.photo.preview(
      id: id, accountID: accountID, chat: chat, expectedRevision: expectedRevision)
  }
  func renderPhoto(
    id: UUID, accountID: UUID, chat: String, expectedRevision: UInt64, mode: WhatsAppPhotoMode
  ) async throws -> WhatsAppPreparedFile {
    if pauseExport { await withCheckedContinuation { continuation = $0 } }
    return try await f.photo.render(
      id: id, accountID: accountID, chat: chat, expectedRevision: expectedRevision, mode: mode)
  }
  func photoDrafts(accountID: UUID, chat: String) async throws -> [WhatsAppPhotoDraft] {
    try await f.photo.drafts(accountID: accountID, chat: chat)
  }
  func saveComposeDraft(_ draft: WhatsAppComposeDraft, expectedRevision: UInt64?) async throws
    -> WhatsAppComposeDraft
  {
    if pauseSave { await withCheckedContinuation { continuation = $0 } }
    return try await f.repository.saveComposeDraft(draft, expectedRevision: expectedRevision)
  }
  func composeDraft(accountID: UUID, chat: String) async throws -> WhatsAppComposeDraft? {
    try await f.repository.composeDraft(accountID: accountID, chat: chat)
  }
  func preparedFile(accountID: UUID, chat: String, id: UUID) async throws -> WhatsAppPreparedFile {
    try await f.files.prepared(id: id, accountID: accountID, chat: chat)
  }
  func prepareFile(accountID: UUID, chat: String, file: URL, kind: String, mime: String)
    async throws -> WhatsAppPreparedFile
  {
    try await f.files.prepare(file: file, accountID: accountID, chat: chat, kind: kind, mime: mime)
  }
  func send(accountID: UUID, chat: String, content: WhatsAppOutgoingContent) async throws
    -> WhatsAppOutgoing
  {
    let row = try await f.repository.prepareOutgoing(
      accountID: accountID, chat: chat, content: content)
    if failNextAdmission {
      failNextAdmission = false
      throw WhatsAppFailure.closed
    }
    return row
  }
}
