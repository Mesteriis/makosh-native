import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

@MainActor final class WhatsAppComposeDraftRecoveryTests: XCTestCase {
  func testComposeRestartRestoresOrderCaptionRecipeWithoutSend() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let worker = PhotoEditorFixtureService(fixture: f)
    let model = WhatsAppComposerModel(worker: worker, synthetic: true)
    model.setContext(account: f.account, chat: "peer@lid")
    await model.restoreDraft()
    model.text = "Caption restart"
    model.photoMode = .hd
    await model.attach([source], asFiles: false, targetAccount: f.account, targetChat: "peer@lid")
    XCTAssertEqual(model.photoDrafts.count, 1)
    XCTAssertTrue(model.attachments.isEmpty)
    let photo = try XCTUnwrap(model.photoDrafts.first)
    _ = try await worker.savePhotoRecipe(
      id: photo.id, accountID: f.account, chat: photo.chat, expectedRevision: photo.revision,
      recipe: .init(operations: [.rotate90]))
    await model.saveDraft()
    let reopened = WhatsAppComposerModel(worker: worker, synthetic: true)
    reopened.setContext(account: f.account, chat: photo.chat)
    await reopened.restoreDraft()
    XCTAssertEqual(reopened.photoMode, .hd)
    XCTAssertEqual(reopened.text, "Caption restart")
    XCTAssertEqual(reopened.photoDrafts.first?.recipe.operations, [.rotate90])
    let rows = try await f.repository.outgoing(accountID: f.account)
    XCTAssertTrue(rows.isEmpty)
    await reopened.send()
    let admitted = try await f.repository.outgoing(accountID: f.account)
    XCTAssertEqual(admitted.count, 1)
    let after = WhatsAppComposerModel(worker: worker, synthetic: true)
    after.setContext(account: f.account, chat: photo.chat)
    await after.restoreDraft()
    XCTAssertEqual(after.text, "")
    XCTAssertTrue(after.photoDrafts.isEmpty)
    XCTAssertNotNil(after.admittedDraft)
    await after.send()
    let repeated = try await f.repository.outgoing(accountID: f.account)
    XCTAssertEqual(repeated.count, 1)
  }
  func testFileModeByteExactAndPhotoModeEdited() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let original = try Data(contentsOf: source)
    let worker = PhotoEditorFixtureService(fixture: f)
    let fileModel = WhatsAppComposerModel(worker: worker, synthetic: true)
    fileModel.setContext(account: f.account, chat: "peer@lid")
    await fileModel.restoreDraft()
    await fileModel.attach(
      [source], asFiles: true, targetAccount: f.account, targetChat: "peer@lid")
    let file = try XCTUnwrap(fileModel.attachments.first)
    let lease = try await f.files.open(file)
    defer { lease.remove() }
    XCTAssertEqual(try Data(contentsOf: lease.url), original)
    XCTAssertTrue(fileModel.photoDrafts.isEmpty)
    let photo = try await worker.capturePhoto(accountID: f.account, chat: "peer@lid", file: source)
    let edited = try await worker.savePhotoRecipe(
      id: photo.id, accountID: f.account, chat: photo.chat, expectedRevision: photo.revision,
      recipe: .init(operations: [.rotate90]))
    let image = try await worker.renderPhoto(
      id: photo.id, accountID: f.account, chat: photo.chat, expectedRevision: edited.revision,
      mode: .standard)
    let imageLease = try await f.files.open(image)
    defer { imageLease.remove() }
    XCTAssertNotEqual(try Data(contentsOf: imageLease.url), original)
    XCTAssertEqual(try Data(contentsOf: source), original)
  }
}
extension WhatsAppComposeDraftRecoveryTests {
  func testMixedPhotoFileOrderSurvivesRestartAndConflictDoesNotOverwrite() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let a = f.root.appendingPathComponent("first.txt")
    let b = f.root.appendingPathComponent("second.txt")
    try Data("one".utf8).write(to: a)
    try Data("two".utf8).write(to: b)
    let worker = PhotoEditorFixtureService(fixture: f)
    let model = WhatsAppComposerModel(
      worker: PhotoEditorFixtureService(fixture: f), synthetic: true)
    model.setContext(account: f.account, chat: "peer@lid")
    await model.restoreDraft()
    await model.attach([a, b], asFiles: true, targetAccount: f.account, targetChat: "peer@lid")
    await model.attach([source], asFiles: false, targetAccount: f.account, targetChat: "peer@lid")
    let photo = try XCTUnwrap(model.photoDrafts.first)
    let files = model.attachments
    model.moveItem(from: 2, to: 0)
    await model.saveDraft()
    let savedValue = try await worker.composeDraft(accountID: f.account, chat: "peer@lid")
    var saved = try XCTUnwrap(savedValue)
    XCTAssertEqual(saved.orderedItems, [.photo(photo.id), .file(files[0].id), .file(files[1].id)])
    saved.text = "Other window"
    _ = try await worker.saveComposeDraft(saved, expectedRevision: saved.revision)
    model.text = "Stale local"
    await model.saveDraft()
    XCTAssertNotNil(model.error)
    let after = try await worker.composeDraft(accountID: f.account, chat: "peer@lid")
    XCTAssertEqual(after?.text, "Other window")
  }
}
extension WhatsAppComposeDraftRecoveryTests {
  func testContextChangeFlushesCaptionBeforeDebounceAndDoesNotClearAdmitted() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = PhotoEditorFixtureService(fixture: f)
    let model = WhatsAppComposerModel(
      worker: PhotoEditorFixtureService(fixture: f), synthetic: true)
    model.setContext(account: f.account, chat: "peer@lid")
    await model.restoreDraft()
    model.text = "Before context switch"
    model.setContext(account: f.account, chat: "second@lid")
    model.text = "Second context"
    await model.flushDrafts()
    let first = try await service.composeDraft(accountID: f.account, chat: "peer@lid")
    let second = try await service.composeDraft(accountID: f.account, chat: "second@lid")
    XCTAssertEqual(first?.text, "Before context switch")
    XCTAssertEqual(second?.text, "Second context")
  }
}
extension WhatsAppComposeDraftRecoveryTests {
  func testFailedContextFlushKeepsLocalDraftOnReturn() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let worker = PhotoEditorFixtureService(fixture: f)
    let model = WhatsAppComposerModel(
      worker: PhotoEditorFixtureService(fixture: f), synthetic: true)
    model.setContext(account: f.account, chat: "peer@lid")
    await model.restoreDraft()
    model.text = "Saved"
    await model.saveDraft()
    let remoteValue = try await worker.composeDraft(accountID: f.account, chat: "peer@lid")
    var remote = try XCTUnwrap(remoteValue)
    remote.text = "Other window"
    _ = try await worker.saveComposeDraft(remote, expectedRevision: remote.revision)
    model.text = "Unsaved local"
    model.setContext(account: f.account, chat: "second@lid")
    await model.flushDrafts()
    model.setContext(account: f.account, chat: "peer@lid")
    await model.restoreDraft()
    XCTAssertEqual(model.text, "Unsaved local")
    XCTAssertNotNil(model.error)
    let unchanged = try await worker.composeDraft(accountID: f.account, chat: "peer@lid")
    XCTAssertEqual(unchanged?.text, "Other window")
  }
}
extension WhatsAppComposeDraftRecoveryTests {
  func testUnloadedExistingDraftCannotBeReboundByEarlySend() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = PhotoEditorFixtureService(fixture: f)
    _ = try await service.saveComposeDraft(
      .init(accountID: f.account, chat: "peer@lid", text: "Existing unobserved draft"),
      expectedRevision: nil)
    let model = WhatsAppComposerModel(worker: service, synthetic: true)
    model.setContext(account: f.account, chat: "peer@lid")
    model.text = "Early new text"
    await model.send()
    let saved = try await service.composeDraft(accountID: f.account, chat: "peer@lid")
    let rows = try await f.repository.outgoing(accountID: f.account)
    XCTAssertEqual(saved?.text, "Existing unobserved draft")
    XCTAssertTrue(rows.isEmpty)
    XCTAssertNotNil(model.error)
  }
  func testLateExplicitReloadCannotClearNewManualText() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = PhotoEditorFixtureService(fixture: f)
    // One boundary owns the suspended save, and only that model uses it.
    let actual = WhatsAppComposerModel(worker: service, synthetic: true)
    actual.setContext(account: f.account, chat: "peer@lid")
    await actual.restoreDraft()
    actual.text = "Before reload"
    await service.suspendSave()
    let saving = Task { await actual.saveDraft() }
    for _ in 0..<200 where !(await service.waiting) { try await Task.sleep(for: .milliseconds(2)) }
    let waiting = await service.waiting
    XCTAssertTrue(waiting)
    let reload = Task { await actual.reloadSavedDraft() }
    await Task.yield()
    actual.text = "Typed while reload waits"
    await service.release()
    await saving.value
    await reload.value
    XCTAssertEqual(actual.text, "Typed while reload waits")
  }
}
extension WhatsAppComposeDraftRecoveryTests {
  func testNewManualIdenticalMessageIsANewIntentAfterAdmission() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = PhotoEditorFixtureService(fixture: f)
    let model = WhatsAppComposerModel(
      worker: PhotoEditorFixtureService(fixture: f), synthetic: true)
    model.setContext(account: f.account, chat: "peer@lid")
    await model.restoreDraft()
    for _ in 0..<2 {
      model.text = "Same manual text"
      await model.send()
    }
    let rows = try await f.repository.outgoing(accountID: f.account)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(Set(rows.map { $0.content.composeRevision }).count, 2)
    let compose = try await service.composeDraft(accountID: f.account, chat: "peer@lid")
    XCTAssertNotNil(compose?.admitted)
  }
}

extension WhatsAppComposeDraftRecoveryTests {
  func testUncertainAdmissionRetryKeepsOriginalIntent() async throws {
    let f = try await WhatsAppPhotoRecoveryTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = PhotoEditorFixtureService(fixture: f)
    let actual = WhatsAppComposerModel(worker: service, synthetic: true)
    actual.setContext(account: f.account, chat: "peer@lid")
    await actual.restoreDraft()
    actual.text = "Unknown receipt"
    await service.failAdmissionOnce()
    await actual.send()
    XCTAssertNotNil(actual.error)
    XCTAssertEqual(actual.text, "Unknown receipt")
    let before = try await f.repository.outgoing(accountID: f.account)
    await actual.send()
    let after = try await f.repository.outgoing(accountID: f.account)
    XCTAssertEqual(after.count, 1)
    XCTAssertEqual(after.first?.id, before.first?.id)
  }
}
