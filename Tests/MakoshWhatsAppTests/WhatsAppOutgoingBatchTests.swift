import Foundation
import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppOutgoingBatchTests: XCTestCase {
  private struct Fixture {
    let a: WhatsAppRepository, b: WhatsAppRepository
    let account: UUID
    let configuration: ContactWorkspaceConfiguration
  }
  private func fixture() async throws -> Fixture {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(
      connectionString: connection,
      schema: "qa_whatsapp_" + suffix, archiveSchema: "qa_whatsapp_archive_" + suffix)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x47, count: 32) }
    let a = WhatsAppRepository(configuration: config, keyProvider: keys)
    let b = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Batch synthetic")
    try await a.saveAccount(account)
    return .init(a: a, b: b, account: account.id, configuration: config)
  }
  private func files(
    _ f: Fixture, count: Int, size: Int64 = 3, account: UUID? = nil, chat: String = "peer@lid"
  ) async throws -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<count {
      let value = WhatsAppPreparedFile(
        id: UUID(), accountID: account ?? f.account, chat: chat,
        name: "synthetic-\(i).txt", kind: "document", mime: "text/plain", size: size)
      try await f.a.savePreparedFile(value)
      ids.append(value.id)
    }
    return ids
  }

  func testBatchAdmissionAtomicBeforeAnyDispatch() async throws {
    let f = try await fixture()
    let ids = try await files(f, count: 3)
    let value = try await f.a.prepareOutgoingBatch(
      accountID: f.account, chat: "peer@lid",
      content: .init(text: "Caption", replyTo: "quoted", files: ids, mentions: ["author@lid"]))
    XCTAssertEqual(value.batch.orderedChildren.map(\.index), [0, 1, 2])
    XCTAssertEqual(value.batch.orderedChildren.map(\.fileID), ids)
    XCTAssertEqual(value.children.count, 3)
    XCTAssertTrue(
      value.children.allSatisfy {
        $0.state == .prepared && $0.stanza == nil && $0.batchID == value.batch.id
      })
    XCTAssertEqual(value.children.map { $0.content.text }, ["Caption", "", ""])
    XCTAssertEqual(value.children.map { $0.content.replyTo }, ["quoted", nil, nil])
    XCTAssertEqual(value.children.map { $0.content.mentions }, [["author@lid"], [], []])
    XCTAssertEqual(
      value.children.map(\.attemptID),
      value.batch.orderedChildren.map { Optional($0.reservedAttemptID) })
    let restored = try await f.b.batch(id: value.batch.id, accountID: f.account)
    XCTAssertEqual(restored.batch, value.batch)
    XCTAssertEqual(restored.children, value.children)
    let rows = try await f.b.outgoing(accountID: f.account)
    XCTAssertEqual(Set(rows.map(\.id)), Set(value.children.map(\.id)))
    XCTAssertFalse(value.blocked)
  }

  func testTenFiles100MiBAnd1000MiBBoundaries() async throws {
    let f = try await fixture()
    let ids = try await files(f, count: 10, size: 100 * 1024 * 1024)
    let max = try await f.a.prepareOutgoingBatch(
      accountID: f.account, chat: "peer@lid", content: .init(text: "", files: ids))
    XCTAssertEqual(max.children.count, 10)
    let tooMany = ids + (try await files(f, count: 1))
    do {
      _ = try await f.a.prepareOutgoingBatch(
        accountID: f.account, chat: "peer@lid", content: .init(text: "", files: tooMany))
      XCTFail("More than10")
    } catch {}
    for size: Int64 in [-1, 100 * 1024 * 1024 + 1, Int64.max] {
      let bad = try await files(f, count: 1, size: size)
      do {
        _ = try await f.a.prepareOutgoingBatch(
          accountID: f.account, chat: "peer@lid", content: .init(text: "", files: bad))
        XCTFail("Invalid size")
      } catch {}
    }
    let rows = try await f.b.outgoing(accountID: f.account)
    XCTAssertEqual(rows.count, 10)
  }

  func testDuplicateAndCrossAccountFileRejected() async throws {
    let f = try await fixture()
    let own = try await files(f, count: 1)
    let other = WhatsAppAccount(name: "Other")
    try await f.a.saveAccount(other)
    let foreign = try await files(f, count: 1, account: other.id)
    let otherChat = try await files(f, count: 1, chat: "another@lid")
    for ids in [[own[0], own[0]], own + foreign, own + otherChat, own + [UUID()]] {
      do {
        _ = try await f.a.prepareOutgoingBatch(
          accountID: f.account, chat: "peer@lid", content: .init(text: "", files: ids))
        XCTFail("Bad references")
      } catch {}
    }
    let rows = try await f.a.outgoing(accountID: f.account)
    XCTAssertTrue(rows.isEmpty)
  }

  func testBatchLeaseBlocksSecondProcessAndStaleRelease() async throws {
    let f = try await fixture()
    let ids = try await files(f, count: 2)
    let batch = try await f.a.prepareOutgoingBatch(
      accountID: f.account, chat: "peer@lid", content: .init(text: "", files: ids))
    let lease = try await f.a.claimBatch(id: batch.batch.id, accountID: f.account)
    do {
      _ = try await f.a.claimBatch(id: batch.batch.id, accountID: f.account)
      XCTFail("No reentrant lease")
    } catch {}
    do {
      _ = try await f.b.claimBatch(id: batch.batch.id, accountID: f.account)
      XCTFail("No other connection owner")
    } catch {}
    XCTAssertEqual(try childLockProbe(configuration: f.configuration, batchID: batch.batch.id), "f")
    try await f.a.releaseBatch(lease)
    let next = try await f.a.claimBatch(id: batch.batch.id, accountID: f.account)
    do {
      try await f.a.releaseBatch(lease)
      XCTFail("Stale lease must not unlock new owner")
    } catch {}
    XCTAssertEqual(try childLockProbe(configuration: f.configuration, batchID: batch.batch.id), "f")
    try await f.a.releaseBatch(next)
    XCTAssertEqual(try childLockProbe(configuration: f.configuration, batchID: batch.batch.id), "t")
  }

  func testReservedAttemptSurvivesRestartAndChildCannotBypassLease() async throws {
    let f = try await fixture()
    let ids = try await files(f, count: 2)
    let batch = try await f.a.prepareOutgoingBatch(
      accountID: f.account, chat: "peer@lid", content: .init(text: "", files: ids))
    let child = try XCTUnwrap(batch.batch.orderedChildren.first)
    let restored = try await f.b.batch(id: batch.batch.id, accountID: f.account)
    XCTAssertEqual(restored.children.first?.attemptID, child.reservedAttemptID)
    do {
      _ = try await f.b.claimOutgoing(id: child.outgoingID, accountID: f.account)
      XCTFail("Batch child needs a lease")
    } catch {}
    let lease = try await f.b.claimBatch(id: batch.batch.id, accountID: f.account)
    let admitted = try await f.b.claimOutgoing(
      id: child.outgoingID, accountID: f.account, batchLease: lease)
    XCTAssertEqual(admitted.attemptID, child.reservedAttemptID)
    try await f.b.settleOutgoing(
      id: admitted.id, accountID: f.account, attemptID: child.reservedAttemptID, outcome: .unknown)
    do {
      try await f.a.resolveOutgoing(id: admitted.id, accountID: f.account, sent: true)
      XCTFail("Foreign live batch owner")
    } catch {}
    do {
      try await f.b.resolveOutgoing(id: admitted.id, accountID: f.account, sent: true)
      XCTFail("Same connection must not reenter a live batch")
    } catch {}
    do {
      _ = try await f.b.claimOutgoing(
        id: batch.batch.orderedChildren[1].outgoingID, accountID: f.account, batchLease: lease)
      XCTFail("Unknown prefix")
    } catch {}
    try await f.b.releaseBatch(lease)
    let blocked = try await f.a.batch(id: batch.batch.id, accountID: f.account)
    XCTAssertTrue(blocked.blocked)
  }

  func testComposeAdmissionAndCrashCannotRecreateBatch() async throws {
    let f = try await fixture()
    let ids = try await files(f, count: 2)
    let draft = try await f.a.saveComposeDraft(
      .init(
        accountID: f.account, chat: "peer@lid", text: "Caption",
        replyTo: "quote", orderedItems: ids.map(WhatsAppComposeItem.file)), expectedRevision: nil)
    XCTAssertEqual(draft.revision, 1)
    var content = WhatsAppOutgoingContent(
      text: draft.text, replyTo: draft.replyTo, files: ids, composeRevision: draft.revision)
    let admitted = try await f.a.prepareOutgoingBatch(
      accountID: f.account, chat: draft.chat, content: content)
    let savedDraft = try await f.b.composeDraft(accountID: f.account, chat: draft.chat)
    let restored = try XCTUnwrap(savedDraft)
    XCTAssertEqual(restored.admitted, .batch(admitted.batch.id))
    let repeated = try await f.b.prepareOutgoingBatch(
      accountID: f.account, chat: draft.chat, content: content)
    XCTAssertEqual(repeated.batch.id, admitted.batch.id)
    let rows = try await f.a.outgoing(accountID: f.account)
    XCTAssertEqual(rows.count, 2)
    content.text = "Changed caption"
    do {
      _ = try await f.b.prepareOutgoingBatch(
        accountID: f.account, chat: draft.chat, content: content)
      XCTFail("Same revision different source")
    } catch {}
    var edited = restored
    edited.admitted = nil
    edited.text = "New intent"
    let next = try await f.b.saveComposeDraft(edited, expectedRevision: restored.revision)
    XCTAssertEqual(next.revision, 2)
    do {
      _ = try await f.a.saveComposeDraft(edited, expectedRevision: restored.revision)
      XCTFail("Stale save")
    } catch {}
    do {
      _ = try await f.a.prepareOutgoingBatch(
        accountID: f.account, chat: draft.chat,
        content: .init(
          text: draft.text, replyTo: draft.replyTo, files: ids, composeRevision: draft.revision))
      XCTFail("Stale admission")
    } catch {}
  }

  func testCommitFailureCannotPublishBatchOrAdmittedComposeMarker() async throws {
    let f = try await fixture()
    let ids = try await files(f, count: 2)
    let draft = try await f.a.saveComposeDraft(
      .init(
        accountID: f.account, chat: "peer@lid", text: "Commit",
        orderedItems: ids.map(WhatsAppComposeItem.file)), expectedRevision: nil)
    try await f.a.installBatchCommitFailureForTests(schema: f.configuration.schema)
    do {
      _ = try await f.a.prepareOutgoingBatch(
        accountID: f.account, chat: draft.chat,
        content: .init(text: draft.text, files: ids, composeRevision: draft.revision))
      XCTFail("COMMIT failed")
    } catch {}
    let rows = try await f.b.outgoing(accountID: f.account)
    let counts = try await f.b.batchCountForTests()
    XCTAssertTrue(rows.isEmpty)
    XCTAssertEqual(counts, 0)
    let restored = try await f.b.composeDraft(accountID: f.account, chat: draft.chat)
    XCTAssertNil(restored?.admitted)
  }

  func testLateNACKStopsContinuation() async throws {
    let f = try await fixture()
    let ids = try await files(f, count: 2)
    let batch = try await f.a.prepareOutgoingBatch(
      accountID: f.account, chat: "peer@lid", content: .init(text: "", files: ids))
    let lease = try await f.a.claimBatch(id: batch.batch.id, accountID: f.account)
    let child = try XCTUnwrap(batch.batch.orderedChildren.first)
    let admitted = try await f.a.claimOutgoing(
      id: child.outgoingID, accountID: f.account, batchLease: lease)
    try await f.a.settleOutgoing(
      id: admitted.id, accountID: f.account, attemptID: child.reservedAttemptID, outcome: .sent)
    var rejection = waRichMessage(kind: "document", text: "")
    rejection.outgoing = true
    rejection.stanza = try XCTUnwrap(admitted.stanza)
    rejection.details = .init()
    rejection.details?.rejection = .init(code: "479", timestamp: 20)
    try await f.b.ingest(
      [.init(sequence: 1, message: rejection, history: true, observed: 20)], accountID: f.account)
    let blocked = try await f.a.batch(id: batch.batch.id, accountID: f.account)
    XCTAssertTrue(blocked.blocked)
    do {
      _ = try await f.a.claimOutgoing(
        id: batch.batch.orderedChildren[1].outgoingID, accountID: f.account, batchLease: lease)
      XCTFail("Rejected prefix")
    } catch {}
    try await f.a.releaseBatch(lease)
  }

  func testLegacySingleOutgoingReadableAndSingleComposeAdmissionIsAtomic() async throws {
    let f = try await fixture()
    let old = try await f.a.prepareOutgoing(
      accountID: f.account, chat: "peer@lid", content: .init(text: "Legacy", files: [UUID()]))
    let restored = try await f.b.outgoing(id: old.id, accountID: f.account)
    XCTAssertNil(restored.batchID)
    XCTAssertNil(restored.content.composeRevision)
    let claim = try await f.b.claimOutgoing(id: old.id, accountID: f.account)
    XCTAssertNotNil(claim.attemptID)
    try await f.b.settleOutgoing(
      id: claim.id, accountID: f.account, attemptID: try XCTUnwrap(claim.attemptID),
      outcome: .notSent)
    let draft = try await f.a.saveComposeDraft(
      .init(accountID: f.account, chat: "peer@lid", text: "Single"), expectedRevision: nil)
    let content = WhatsAppOutgoingContent(text: "Single", composeRevision: draft.revision)
    let single = try await f.a.prepareOutgoing(
      accountID: f.account, chat: draft.chat, content: content)
    let repeatSingle = try await f.b.prepareOutgoing(
      accountID: f.account, chat: draft.chat, content: content)
    XCTAssertEqual(single.id, repeatSingle.id)
    let saved = try await f.b.composeDraft(accountID: f.account, chat: draft.chat)
    XCTAssertEqual(saved?.admitted, .outgoing(single.id))
  }

  private func childLockProbe(configuration: ContactWorkspaceConfiguration, batchID: UUID) throws
    -> String
  {
    let library = "/opt/homebrew/opt/libpq/lib/libpq.5.dylib"
    guard FileManager.default.fileExists(atPath: library) else {
      throw XCTSkip("Child libpq unavailable")
    }
    let script = """
      import ctypes, os, sys, uuid
      p=ctypes.CDLL(os.environ['WA_TEST_LIBPQ'])
      p.PQconnectdb.argtypes=[ctypes.c_char_p]; p.PQconnectdb.restype=ctypes.c_void_p
      p.PQstatus.argtypes=[ctypes.c_void_p]; p.PQstatus.restype=ctypes.c_int
      p.PQexec.argtypes=[ctypes.c_void_p,ctypes.c_char_p]; p.PQexec.restype=ctypes.c_void_p
      p.PQresultStatus.argtypes=[ctypes.c_void_p]; p.PQresultStatus.restype=ctypes.c_int
      p.PQgetvalue.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int]; p.PQgetvalue.restype=ctypes.c_char_p
      p.PQclear.argtypes=[ctypes.c_void_p]; p.PQfinish.argtypes=[ctypes.c_void_p]
      c=p.PQconnectdb(os.environ['WA_TEST_DSN'].encode())
      if not c or p.PQstatus(c)!=0: sys.exit(2)
      try:
          ident=str(uuid.UUID(os.environ['WA_TEST_BATCH'])).upper()
          r=p.PQexec(c,("SELECT pg_try_advisory_lock(hashtextextended('"+ident+"',17403))").encode())
          if not r or p.PQresultStatus(r)!=2: sys.exit(3)
          try: print(p.PQgetvalue(r,0,0).decode())
          finally: p.PQclear(r)
      finally: p.PQfinish(c)
      """
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["WA_TEST_LIBPQ"] = library
    environment["WA_TEST_DSN"] = configuration.connectionString
    environment["WA_TEST_BATCH"] = batchID.uuidString
    environment["PGCONNECT_TIMEOUT"] = "5"
    process.environment = environment
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
extension WhatsAppRepository {
  fileprivate func installBatchCommitFailureForTests(schema: String) throws {
    guard schema.hasPrefix("qa_whatsapp_"), ArchiveBackup.isValidSchemaName(schema) else {
      throw WhatsAppFailure.invalid
    }
    let db = try db()
    _ = try db.query(
      "CREATE FUNCTION \"\(schema)\".wa_fail_batch_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic deferred failure'; END; $$"
    )
    _ = try db.query(
      "CREATE CONSTRAINT TRIGGER wa_fail_batch AFTER INSERT ON \(db.batchesTable) DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION \"\(schema)\".wa_fail_batch_commit()"
    )
  }
  fileprivate func batchCountForTests() throws -> Int {
    let db = try db()
    return Int(try db.query("SELECT count(*) FROM \(db.batchesTable)").first?.first ?? "") ?? -1
  }
}
