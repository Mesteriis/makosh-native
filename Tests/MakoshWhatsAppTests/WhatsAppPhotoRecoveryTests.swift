import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppPhotoRecoveryTests: XCTestCase {
  struct Fixture {
    let repository: WhatsAppRepository, files: WhatsAppFiles, photo: WhatsAppPhotoPreparation
    let root: URL, account: UUID
  }
  func fixture(renderer: WhatsAppPhotoPreparation.Renderer? = nil) async throws -> Fixture {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(
      connectionString: connection, schema: "qa_whatsapp_" + suffix,
      archiveSchema: "qa_whatsapp_archive_" + suffix)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x65, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Photo synthetic")
    try await repository.saveAccount(account)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let storage = root.appendingPathComponent("s3.json")
    try JSONSerialization.data(withJSONObject: [
      "endpoint": "http://127.0.0.1:1", "region": "qa", "bucket": "qa-whatsapp",
      "accessKeyID": "synthetic", "secretAccessKey": "synthetic",
    ]).write(to: storage)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storage.path)
    let files = WhatsAppFiles(
      configuration: config, storageFile: storage, spool: root.appendingPathComponent("spool"),
      repository: repository, keyProvider: keys)
    try await files.setSaving(accountID: account.id, chat: "peer@lid", enabled: false)
    let photo = WhatsAppPhotoPreparation(repository: repository, files: files, renderer: renderer)
    return .init(
      repository: repository, files: files, photo: photo, root: root, account: account.id)
  }
  func testRecipeRestartUsesSameSourceAndExportReceipt() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let initial = try await f.photo.capture(file: source, accountID: f.account, chat: "peer@lid")
    let draft = try await f.photo.saveRecipe(
      id: initial.id, accountID: f.account, chat: initial.chat, expectedRevision: initial.revision,
      recipe: .init(operations: [.rotate90]))
    let file = try await f.photo.render(
      id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: draft.revision,
      mode: .standard)
    let restarted = WhatsAppPhotoPreparation(repository: f.repository, files: f.files)
    let all = try await restarted.drafts(accountID: f.account, chat: draft.chat)
    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(all[0].sourceID, draft.sourceID)
    XCTAssertEqual(all[0].recipe, draft.recipe)
    try await f.files.setSaving(accountID: f.account, chat: draft.chat, enabled: true)
    let same = try await restarted.render(
      id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: draft.revision,
      mode: .standard)
    XCTAssertEqual(same, file)
    XCTAssertEqual(same.record?.state, .local)
    do {
      _ = try await restarted.saveRecipe(
        id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: initial.revision,
        recipe: .init())
      XCTFail("Stale CAS")
    } catch {}
  }
  func testPhotoOFFNeverPutsAnyDerivative() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let draft = try await f.photo.capture(file: source, accountID: f.account, chat: "peer@lid")
    let preview = try await f.photo.preview(
      id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: draft.revision)
    XCTAssertEqual(preview.width, 80)
    let file = try await f.photo.render(
      id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: draft.revision,
      mode: .hd)
    XCTAssertEqual(file.record?.state, .local)
    let original = try await f.files.prepared(
      id: draft.sourceID, accountID: f.account, chat: draft.chat)
    XCTAssertEqual(original.record?.state, .local)
    let lease = try await f.files.open(original)
    defer { lease.remove() }
    XCTAssertEqual(try Data(contentsOf: lease.url), try Data(contentsOf: source))
    let compose = try await f.repository.saveComposeDraft(
      .init(
        accountID: f.account, chat: draft.chat, text: "caption", orderedItems: [.photo(draft.id)]),
      expectedRevision: nil)
    let updated = try await f.photo.saveRecipe(
      id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: draft.revision,
      recipe: .init(operations: [.rotate90]))
    do {
      _ = try await f.repository.prepareOutgoing(
        accountID: f.account, chat: draft.chat,
        content: .init(text: "caption", files: [file.id], composeRevision: compose.revision))
      XCTFail("Old photo export must not be admitted")
    } catch {}
    let fresh = try await f.photo.render(
      id: updated.id, accountID: f.account, chat: draft.chat, expectedRevision: updated.revision,
      mode: .standard)
    let admitted = try await f.repository.prepareOutgoing(
      accountID: f.account, chat: draft.chat,
      content: .init(text: "caption", files: [fresh.id], composeRevision: compose.revision))
    XCTAssertEqual(admitted.content.files, [fresh.id])
  }
  func testLateRenderCannotReplaceNewRecipe() async throws {
    let gate = PhotoRenderGate()
    let f = try await fixture(renderer: { source, recipe, mode in
      await gate.wait()
      return try WhatsAppPhotoRenderer.render(source: source, recipe: recipe, mode: mode)
    })
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let draft = try await f.photo.capture(file: source, accountID: f.account, chat: "peer@lid")
    let task = Task {
      try await f.photo.render(
        id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: draft.revision,
        mode: .hd)
    }
    while !(await gate.started) { await Task.yield() }
    let updated = try await f.photo.saveRecipe(
      id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: draft.revision,
      recipe: .init(operations: [.rotate90]))
    await gate.release()
    do {
      _ = try await task.value
      XCTFail("Stale render")
    } catch {}
    let all = try await f.photo.drafts(accountID: f.account, chat: draft.chat)
    XCTAssertEqual(all.first?.revision, updated.revision)
    XCTAssertNil(all.first?.exportedFileID)
    let envelopes = try FileManager.default.contentsOfDirectory(
      at: f.root.appendingPathComponent("spool"), includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "envelope" }
    XCTAssertEqual(envelopes.count, 1, "Only immutable source; stale derivative never admitted")
  }
}
private actor PhotoRenderGate {
  var started = false
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    started = true
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}
extension WhatsAppPhotoRecoveryTests {
  func testPendingSourceRecoversSameLocalIDWithoutNewCopies() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let pending = WhatsAppPhotoDraft(
      id: UUID(), accountID: f.account, sourceID: UUID(), chat: "peer@lid")
    try await f.repository.insertPhoto(pending)
    let original = try await f.files.prepare(
      file: source, accountID: f.account, chat: pending.chat, kind: "document",
      mime: "application/octet-stream", reservedID: pending.sourceID, localOnly: true)
    try await f.files.setSaving(accountID: f.account, chat: pending.chat, enabled: true)
    let restarted = WhatsAppPhotoPreparation(repository: f.repository, files: f.files)
    let drafts = try await restarted.drafts(accountID: f.account, chat: pending.chat)
    let restored = try XCTUnwrap(drafts.first)
    XCTAssertEqual(restored.id, pending.id)
    XCTAssertEqual(restored.sourceID, pending.sourceID)
    XCTAssertTrue(restored.sourceReady)
    XCTAssertEqual(restored.width, 80)
    XCTAssertEqual(restored.height, 40)
    let receipt = try await f.files.prepared(
      id: pending.sourceID, accountID: f.account, chat: pending.chat)
    XCTAssertEqual(receipt, original)
    XCTAssertEqual(receipt.record?.state, .local)
    let envelopes = try FileManager.default.contentsOfDirectory(
      at: f.root.appendingPathComponent("spool"), includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "envelope" }
    XCTAssertEqual(envelopes.count, 1)
  }
}
extension WhatsAppPhotoRecoveryTests {
  func testConfirmedExportRecoversReceiptBeforeAnyRerender() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = try photoFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let draft = try await f.photo.capture(file: source, accountID: f.account, chat: "peer@lid")
    let file = try await f.photo.render(
      id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: draft.revision,
      mode: .hd)
    var interrupted = file
    interrupted.record = nil
    try await f.repository.savePreparedFile(interrupted)
    try await f.files.setSaving(accountID: f.account, chat: draft.chat, enabled: true)
    let restarted = WhatsAppPhotoPreparation(
      repository: f.repository, files: f.files,
      renderer: { _, _, _ in throw WhatsAppFailure.unavailable })
    let restored = try await restarted.render(
      id: draft.id, accountID: f.account, chat: draft.chat, expectedRevision: draft.revision,
      mode: .hd)
    XCTAssertEqual(restored, file)
    XCTAssertEqual(restored.record?.state, .local)
  }
}
