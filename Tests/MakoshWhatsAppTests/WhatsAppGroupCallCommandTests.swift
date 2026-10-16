import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppGroupCallCommandTests: XCTestCase {
  struct Fixture {
    let worker: WhatsAppWorker, repository: WhatsAppRepository, transport: GroupCommandTransport
    let account: UUID
  }
  func fixture() async throws -> Fixture {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(
      connectionString: connection, schema: "qa_whatsapp_" + suffix,
      archiveSchema: "qa_whatsapp_archive_" + suffix)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x38, count: 32) }
    let repo = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Group command synthetic")
    try await repo.saveAccount(account)
    let transport = GroupCommandTransport()
    let worker = WhatsAppWorker(factory: { _ in transport }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    try await worker.connect(accountID: account.id)
    return .init(worker: worker, repository: repo, transport: transport, account: account.id)
  }
  func testGroupStartHasDurableAttemptAndNeverBecomesResumable() async throws {
    let f = try await fixture()
    for targets in [["200@lid"], ["200@lid", "200@lid"], (0..<32).map { "20\($0)@lid" }] {
      do {
        _ = try await f.worker.startGroupCall(
          accountID: f.account, groupJID: "500@g.us", participants: targets, video: false)
        XCTFail("Invalid targets")
      } catch {}
    }
    let row = try await f.worker.startGroupCall(
      accountID: f.account, groupJID: "500@g.us", participants: ["200@lid", "300@lid"], video: true)
    XCTAssertEqual(row.state, .sent)
    XCTAssertEqual(row.callEpoch, 11)
    let reopened = try await f.repository.outgoing(id: row.id, accountID: f.account)
    XCTAssertEqual(reopened.callEpoch, 11)
    XCTAssertEqual(row.content.action?.op, .callGroupStart)
    XCTAssertEqual(row.content.action?.options, ["200@lid", "300@lid"])
    let actions = await f.transport.actions
    XCTAssertEqual(actions.count, 1)
    XCTAssertEqual(actions[0].1.attempt, row.attemptID?.uuidString.lowercased())
    do {
      _ = try await f.worker.resumeOutgoing(accountID: f.account, id: row.id)
      XCTFail("No call replay")
    } catch {}
    await f.worker.shutdown()
  }
  func testInviteRingAndLeaveBoundToCallEpoch() async throws {
    let f = try await fixture()
    for (call, epoch, jid, ring) in [
      ("other", UInt64(11), "400@lid", false), ("GROUP", 12, "400@lid", false),
      ("GROUP", 11, "400@lid", true),
    ] {
      do {
        _ = try await f.worker.inviteCallParticipant(
          accountID: f.account, callID: call, epoch: epoch, jid: jid, ringOnly: ring)
        XCTFail("Stale/absent roster")
      } catch {}
    }
    let invite = try await f.worker.inviteCallParticipant(
      accountID: f.account, callID: "GROUP", epoch: 11, jid: "400@lid", ringOnly: false)
    let ring = try await f.worker.inviteCallParticipant(
      accountID: f.account, callID: "GROUP", epoch: 11, jid: "200@lid", ringOnly: true)
    XCTAssertEqual(invite.content.action?.op, .callInvite)
    XCTAssertEqual(ring.content.action?.op, .callRing)
    XCTAssertEqual(ring.content.action?.callEpoch, 11)
    XCTAssertEqual(ring.content.action?.to, "200@lid")
    await f.worker.shutdown()
  }
  func testEndBeforeDelayedStatusRejectsGroupStartAndInvite() async throws {
    for invitation in [false, true] {
      let f = try await fixture()
      await f.transport.pauseStatus()
      let task = Task {
        if invitation {
          return try await f.worker.inviteCallParticipant(
            accountID: f.account, callID: "GROUP", epoch: 11, jid: "400@lid", ringOnly: false)
        }
        return try await f.worker.startGroupCall(
          accountID: f.account, groupJID: "500@g.us", participants: ["200@lid", "300@lid"],
          video: false)
      }
      for _ in 0..<200 where !(await f.transport.waiting) {
        try await Task.sleep(for: .milliseconds(2))
      }
      let waiting = await f.transport.waiting
      XCTAssertTrue(waiting)
      if !waiting { await f.transport.release() }
      var end = WhatsAppAction(.callEnd, target: "GROUP")
      end.callEpoch = 11
      _ = try await f.worker.perform(accountID: f.account, chat: "500@g.us", action: end)
      await f.transport.release()
      do {
        _ = try await task.value
        XCTFail("Revoked call revision")
      } catch {}
      let ops = await f.transport.actions.map { $0.1.op }
      XCTAssertEqual(ops, [.callEnd])
      await f.worker.shutdown()
    }
  }
}
actor GroupCommandTransport: WhatsAppTransport {
  var actions: [(String, WhatsAppAction)] = []
  var pause = false, continuation: CheckedContinuation<Void, Never>?
  var waiting: Bool { continuation != nil }
  var call = WhatsAppCallSnapshot(
    id: "GROUP", epoch: 11, peer: "500@g.us", state: "active", incoming: false, video: false,
    remoteVideo: false, videoRequested: false, muted: false,
    group: .init(
      groupJID: "500@g.us", rosterRevision: 1,
      participants: [
        .init(jid: "200@lid", state: "disconnected", devices: []),
        .init(jid: "300@lid", state: "connected", devices: []),
      ], participantLimit: 32))
  func pauseStatus() { pause = true }
  func release() {
    pause = false
    continuation?.resume()
    continuation = nil
  }
  func connect() {}
  func disconnect() {}
  func close() {}
  func status() async -> WhatsAppConnectionStatus {
    if pause {
      pause = false
      await withCheckedContinuation { continuation = $0 }
    }
    var status = WhatsAppConnectionStatus()
    status.state = "connected"
    status.call = call
    return status
  }
  func chats(before: WhatsAppCursor?) -> [WhatsAppChat] { [] }
  func journal() -> [WhatsAppJournalEntry] { [] }
  func acknowledge(_ sequence: Int64) {}
  func perform(chat: String, action: WhatsAppAction) -> WhatsAppMutationResult {
    actions.append((chat, action))
    if action.op == .callGroupStart {
      call.id = "GROUP-NEW"
      call.state = "active"
    }
    if action.op == .callEnd { call.state = "ended" }
    return .init(
      stanza: action.op == .callGroupStart ? "GROUP-NEW" : "CONTROL",
      callEpoch: action.op == .callGroupStart ? 11 : nil)
  }
}
extension WhatsAppGroupCallCommandTests {
  func testAcceptedReceiptCleanupUsesExactCallAndRejectsNewSession() async throws {
    let f = try await fixture()
    let receipt = try await f.worker.startGroupCall(
      accountID: f.account, groupJID: "500@g.us", participants: ["200@lid", "300@lid"], video: false
    )
    try await f.worker.cancelAcceptedCall(accountID: f.account, outgoingID: receipt.id)
    let first = await f.transport.actions.last?.1
    XCTAssertEqual(first?.op, .callEnd)
    XCTAssertEqual(first?.target, "GROUP-NEW")
    XCTAssertEqual(first?.callEpoch, 11)
    await f.worker.shutdown()
    let next = try await fixture()
    let old = try await next.worker.startGroupCall(
      accountID: next.account, groupJID: "500@g.us", participants: ["200@lid", "300@lid"],
      video: false)
    try await next.worker.disconnect(accountID: next.account)
    try await next.worker.connect(accountID: next.account)
    do {
      try await next.worker.cancelAcceptedCall(accountID: next.account, outgoingID: old.id)
      XCTFail("Old session cannot end reused ID/epoch")
    } catch {}
    let actions = await next.transport.actions
    XCTAssertFalse(actions.contains { $0.1.op == .callEnd })
    await next.worker.shutdown()
  }
}
