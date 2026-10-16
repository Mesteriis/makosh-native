import Foundation
import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppBatchDispatchTests: XCTestCase {
  private struct Fixture {
    let worker: WhatsAppWorker, repository: WhatsAppRepository, files: WhatsAppFiles
    let transport: BatchSendingTransport
    let account: UUID, configuration: ContactWorkspaceConfiguration, root: URL
    let keys: @Sendable (UUID, Bool) throws -> Data
  }
  private func fixture(mode: BatchSendingTransport.Mode = .success, synthetic: Bool = false)
    async throws -> Fixture
  {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(
      connectionString: connection, schema: "qa_whatsapp_" + suffix,
      archiveSchema: "qa_whatsapp_archive_" + suffix)
    let raw = synthetic ? UInt8(0x79) : UInt8(0x68)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: raw, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Batch worker fixture")
    try await repository.saveAccount(account)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wa-batch-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let storage = root.appendingPathComponent("s3.json")
    try JSONSerialization.data(withJSONObject: [
      "endpoint": "http://127.0.0.1:1", "region": "qa", "bucket": "qa-whatsapp",
      "accessKeyID": "synthetic", "secretAccessKey": "synthetic-only",
    ]).write(to: storage)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storage.path)
    let files = WhatsAppFiles(
      configuration: config, storageFile: storage, spool: root.appendingPathComponent("spool"),
      repository: repository, keyProvider: keys)
    try await files.setSaving(accountID: account.id, chat: "peer@lid", enabled: false)
    let transport = BatchSendingTransport(mode: mode, repository: repository, account: account.id)
    let worker =
      synthetic
      ? WhatsAppWorker(synthetic: true)
      : WhatsAppWorker(factory: { _ in transport }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    await worker.installBatchFilesForTests(files)
    if !synthetic { try await worker.connect(accountID: account.id) }
    return .init(
      worker: worker, repository: repository, files: files, transport: transport,
      account: account.id, configuration: config, root: root, keys: keys)
  }
  private func prepare(_ f: Fixture, count: Int = 3) async throws -> [WhatsAppPreparedFile] {
    var values: [WhatsAppPreparedFile] = []
    for i in 0..<count {
      let url = f.root.appendingPathComponent("batch-\(i).txt")
      try Data("synthetic-\(i)".utf8).write(to: url)
      let value = try await f.worker.prepareFile(
        accountID: f.account, chat: "peer@lid", file: url, kind: "document", mime: "text/plain")
      XCTAssertEqual(value.record?.state, .local)
      values.append(value)
    }
    return values
  }
  func testThreeFileBatchStopsAfterUnknownSecondWithoutReplayingFirst() async throws {
    let f = try await fixture(mode: .unknownSecond)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let files = try await prepare(f)
    let batch = try await f.worker.sendBatch(
      accountID: f.account, chat: "peer@lid",
      content: .init(text: "caption", replyTo: "quoted", files: files.map(\.id)))
    XCTAssertEqual(batch.children.map(\.state), [.sent, .unknown, .prepared])
    let calls = await f.transport.calls
    XCTAssertEqual(calls.map(\.name), ["batch-0.txt", "batch-1.txt"])
    XCTAssertEqual(calls.map(\.text), ["caption", ""])
    XCTAssertEqual(calls.map(\.reply), ["quoted", nil])
    XCTAssertEqual(
      calls.map(\.attempt),
      batch.batch.orderedChildren.prefix(2).map { $0.reservedAttemptID.uuidString.lowercased() })
    XCTAssertTrue(calls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    for _ in 0..<3 { _ = try await f.worker.snapshot(accountID: f.account) }
    let after = await f.transport.calls
    XCTAssertEqual(after.count, 2)
    await f.worker.shutdown()
  }
  func testRejectedOrLateNACKBlocksRemainingChildren() async throws {
    for mode in [BatchSendingTransport.Mode.rejectFirst, .lateNACKDuringSecond] {
      let f = try await fixture(mode: mode)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let files = try await prepare(f)
      let batch = try await f.worker.sendBatch(
        accountID: f.account, chat: "peer@lid", content: .init(text: "", files: files.map(\.id)))
      let calls = await f.transport.calls
      XCTAssertEqual(calls.count, mode == .rejectFirst ? 1 : 2)
      XCTAssertEqual(batch.children.first?.state, .rejected)
      XCTAssertEqual(batch.children.last?.state, .prepared)
      if mode == .lateNACKDuringSecond { XCTAssertEqual(batch.children[1].state, .sent) }
      await f.worker.shutdown()
    }
  }
  func testExplicitContinuationSendsOnlyPreparedChildren() async throws {
    let f = try await fixture(mode: .unknownSecond)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let files = try await prepare(f)
    let batch = try await f.worker.sendBatch(
      accountID: f.account, chat: "peer@lid", content: .init(text: "", files: files.map(\.id)))
    let blocked = try await f.worker.continueBatch(accountID: f.account, id: batch.batch.id)
    XCTAssertTrue(blocked.blocked)
    let before = await f.transport.calls
    XCTAssertEqual(before.count, 2)
    do {
      _ = try await f.worker.resumeOutgoing(accountID: f.account, id: batch.children[2].id)
      XCTFail("No individual batch resume")
    } catch {}
    try await f.worker.resolveOutgoing(accountID: f.account, id: batch.children[1].id, sent: true)
    let resolved = await f.transport.calls
    XCTAssertEqual(resolved.count, 2)
    try await f.files.setSaving(accountID: f.account, chat: "peer@lid", enabled: true)
    let completed = try await f.worker.continueBatch(accountID: f.account, id: batch.batch.id)
    XCTAssertEqual(completed.children.map(\.state), [.sent, .sent, .sent])
    let calls = await f.transport.calls
    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(
      calls.last?.attempt, batch.batch.orderedChildren[2].reservedAttemptID.uuidString.lowercased())
    let local = try await f.files.prepared(id: files[2].id, accountID: f.account, chat: "peer@lid")
    XCTAssertEqual(local.record?.state, .local, "Enabling cannot promote existing preparations")
    await f.worker.shutdown()
  }
  func testExplicitContinuationSkipsKnownFailureButANewNACKStillStops() async throws {
    let f = try await fixture(mode: .rejectFirst)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let files = try await prepare(f)
    let batch = try await f.worker.sendBatch(
      accountID: f.account, chat: "peer@lid", content: .init(text: "", files: files.map(\.id)))
    let continued = try await f.worker.continueBatch(accountID: f.account, id: batch.batch.id)
    XCTAssertEqual(continued.children.map(\.state), [.rejected, .sent, .sent])
    let calls = await f.transport.calls
    XCTAssertEqual(calls.map(\.name), ["batch-0.txt", "batch-1.txt", "batch-2.txt"])
    XCTAssertEqual(
      calls.map(\.attempt),
      batch.batch.orderedChildren.map { $0.reservedAttemptID.uuidString.lowercased() })
    await f.worker.shutdown()
  }
  func testRestartNeverDispatchesBatch() async throws {
    let f = try await fixture(mode: .unknownSecond)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let files = try await prepare(f)
    let batch = try await f.worker.sendBatch(
      accountID: f.account, chat: "peer@lid", content: .init(text: "", files: files.map(\.id)))
    await f.worker.shutdown()
    let transport = BatchSendingTransport(
      mode: .success, repository: f.repository, account: f.account)
    let restarted = WhatsAppWorker(factory: { _ in transport }, keyProvider: f.keys)
    _ = try await restarted.load(configuration: f.configuration)
    await restarted.installBatchFilesForTests(f.files)
    _ = try await restarted.snapshot(accountID: f.account)
    let saved = try await restarted.batch(accountID: f.account, id: batch.batch.id)
    XCTAssertEqual(saved.children.map(\.state), [.sent, .unknown, .prepared])
    let calls = await transport.calls
    XCTAssertTrue(calls.isEmpty)
    await restarted.shutdown()
  }
  func testNewNACKDuringExplicitContinuationStopsBeforeNextChild() async throws {
    let f = try await fixture(mode: .rejectFirstThenLateNACKDuringThird)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let files = try await prepare(f, count: 4)
    let batch = try await f.worker.sendBatch(
      accountID: f.account, chat: "peer@lid", content: .init(text: "", files: files.map(\.id)))
    let continued = try await f.worker.continueBatch(accountID: f.account, id: batch.batch.id)
    XCTAssertEqual(continued.children.map(\.state), [.rejected, .rejected, .sent, .prepared])
    let calls = await f.transport.calls
    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(
      calls.map(\.attempt),
      batch.batch.orderedChildren.prefix(3).map { $0.reservedAttemptID.uuidString.lowercased() })
    await f.worker.shutdown()
  }
  func testExplicitCopyClearsConsumedComposeRevisionAndDoesNotDispatch() async throws {
    let f = try await fixture(mode: .notAdmittedFirst)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let files = try await prepare(f, count: 1)
    let draft = try await f.repository.saveComposeDraft(
      .init(
        accountID: f.account, chat: "peer@lid", text: "copy",
        orderedItems: [.file(files[0].id)]), expectedRevision: nil)
    do {
      _ = try await f.worker.send(
        accountID: f.account, chat: "peer@lid",
        content: .init(text: "copy", files: files.map(\.id), composeRevision: draft.revision))
      XCTFail("Not admitted")
    } catch {}
    let rows = try await f.repository.outgoing(accountID: f.account)
    let original = try XCTUnwrap(rows.first)
    XCTAssertEqual(original.state, .notSent)
    let copied = try await f.worker.copyOutgoing(accountID: f.account, id: original.id)
    XCTAssertNotEqual(copied.id, original.id)
    XCTAssertEqual(copied.state, .prepared)
    XCTAssertNil(copied.content.composeRevision)
    XCTAssertNil(copied.batchID)
    let calls = await f.transport.calls
    XCTAssertEqual(calls.count, 1)
    await f.worker.shutdown()
  }
  func testSyntheticBatchOnlyAdmitsPreparedAndNeverConnects() async throws {
    let f = try await fixture(synthetic: true)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let files = try await prepare(f)
    let batch = try await f.worker.sendBatch(
      accountID: f.account, chat: "peer@lid", content: .init(text: "", files: files.map(\.id)))
    XCTAssertEqual(batch.children.count, 3)
    XCTAssertTrue(batch.children.allSatisfy { $0.state == .prepared })
    let snapshot = try await f.worker.snapshot(accountID: f.account)
    XCTAssertFalse(snapshot.status.linked)
    let calls = await f.transport.calls
    XCTAssertTrue(calls.isEmpty)
    await f.worker.shutdown()
  }
  func testCancellationDrainsCurrentReceiptAndLeavesRemainderPrepared() async throws {
    let f = try await fixture(mode: .suspendSecond)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let files = try await prepare(f)
    let sending = Task {
      try await f.worker.sendBatch(
        accountID: f.account, chat: "peer@lid", content: .init(text: "", files: files.map(\.id)))
    }
    for _ in 0..<100 where !(await f.transport.waitingSecond()) {
      try await Task.sleep(for: .milliseconds(2))
    }
    let waiting = await f.transport.waitingSecond()
    XCTAssertTrue(waiting)
    sending.cancel()
    await f.transport.releaseSecond()
    let stopped = try await sending.value
    XCTAssertEqual(stopped.children.map(\.state), [.sent, .sent, .prepared])
    XCTAssertEqual(stopped.issue?.reason, .cancelled)
    let before = await f.transport.calls
    XCTAssertEqual(before.count, 2)
    let continued = try await f.worker.continueBatch(accountID: f.account, id: stopped.batch.id)
    XCTAssertEqual(continued.children.map(\.state), [.sent, .sent, .sent])
    let calls = await f.transport.calls
    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(
      calls.last?.attempt,
      stopped.batch.orderedChildren[2].reservedAttemptID.uuidString.lowercased())
    await f.worker.shutdown()
  }
}

extension WhatsAppWorker {
  fileprivate func installBatchFilesForTests(_ files: WhatsAppFiles) { self.files = files }
}
private actor BatchSendingTransport: WhatsAppTransport {
  enum Mode: Equatable, Sendable {
    case success, unknownSecond, rejectFirst, lateNACKDuringSecond,
      rejectFirstThenLateNACKDuringThird, notAdmittedFirst, suspendSecond
  }
  let mode: Mode, repository: WhatsAppRepository, account: UUID
  private(set) var calls: [WhatsAppAction] = []
  private var nackSequence: Int64 = 0
  private var second: CheckedContinuation<Void, Never>?
  func waitingSecond() -> Bool { second != nil }
  func releaseSecond() {
    second?.resume()
    second = nil
  }
  init(mode: Mode, repository: WhatsAppRepository, account: UUID) {
    self.mode = mode
    self.repository = repository
    self.account = account
  }
  func connect() {}
  func disconnect() {}
  func close() {}
  func status() -> WhatsAppConnectionStatus {
    var value = WhatsAppConnectionStatus()
    value.state = "connected"
    return value
  }
  func chats(before: WhatsAppCursor?) -> [WhatsAppChat] { [] }
  func journal() -> [WhatsAppJournalEntry] { [] }
  func acknowledge(_ sequence: Int64) {}
  func perform(chat: String, action: WhatsAppAction) async throws -> WhatsAppMutationResult {
    calls.append(action)
    XCTAssertEqual(action.op, .media)
    XCTAssertFalse(try Data(contentsOf: URL(fileURLWithPath: action.path)).isEmpty)
    if mode == .suspendSecond && calls.count == 2 { await withCheckedContinuation { second = $0 } }
    let stanza = "MK" + action.attempt.replacingOccurrences(of: "-", with: "").uppercased()
    if mode == .notAdmittedFirst && calls.count == 1 { throw WhatsAppFailure.notAdmitted }
    if mode == .unknownSecond && calls.count == 2 { throw WhatsAppFailure.protocolFailure }
    if mode == .rejectFirst && calls.count == 1 || mode == .lateNACKDuringSecond && calls.count == 2
      || mode == .rejectFirstThenLateNACKDuringThird && [1, 3].contains(calls.count)
    {
      let target: String
      if mode == .lateNACKDuringSecond {
        target = calls[0].attempt
      } else if calls.count == 3 {
        target = calls[1].attempt
      } else {
        target = action.attempt
      }
      let targetStanza = "MK" + target.replacingOccurrences(of: "-", with: "").uppercased()
      var message = WhatsAppMessage(
        chat: chat, id: targetStanza, stanza: targetStanza,
        sender: "peer@lid", timestamp: 20, outgoing: true, text: "", kind: "document",
        edited: false, deleted: false)
      message.details = .init()
      message.details?.rejection = .init(code: "479", timestamp: 20)
      nackSequence += 1
      try await repository.ingest(
        [.init(sequence: nackSequence, message: message, history: true, observed: 20)],
        accountID: account)
    }
    return .init(stanza: stanza)
  }
}
