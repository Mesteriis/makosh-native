import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppOutboxTests: XCTestCase {
  private func repositories() async throws -> (WhatsAppRepository, WhatsAppRepository, UUID) {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PostgreSQL required")
    }
    let config = ContactWorkspaceConfiguration(
      connectionString: connection,
      schema: "qa_whatsapp_"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    let key: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x79, count: 32) }
    let a = WhatsAppRepository(configuration: config, keyProvider: key)
    let b = WhatsAppRepository(configuration: config, keyProvider: key)
    let id = UUID()
    try await a.saveAccount(.init(id: id, name: "Outbox"))
    return (a, b, id)
  }
  func testOutboxPagesRetainEveryRowWithStableCursor() async throws {
    let (a, b, id) = try await repositories()
    var expected = Set<UUID>()
    for n in 0..<55 {
      expected.insert(try await a.prepareOutgoing(accountID: id, chat: "peer@lid", content: .init(text: "message \(n)")).id)
    }
    var cursor: WhatsAppOutgoingCursor?
    var actual: [UUID] = []
    repeat {
      let page = try await b.outgoingPage(accountID: id, before: cursor, limit: 7)
      XCTAssertLessThanOrEqual(page.values.count, 7)
      actual += page.values.map(\.id)
      cursor = page.next
    } while cursor != nil
    XCTAssertEqual(Set(actual), expected)
    XCTAssertEqual(actual.count, 55)
  }
  func testNegativeAcknowledgementBeforeOrAfterSettlementRemainsRejected() async throws {
    let (a, b, account) = try await repositories()
    for early in [true, false] {
      let draft = try await a.prepareOutgoing(accountID: account, chat: "peer@lid", content: .init(text: "rejected"))
      let claimed = try await a.claimOutgoing(id: draft.id, accountID: account)
      let attempt = try XCTUnwrap(claimed.attemptID)
      let stanza = "MK" + attempt.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
      let payload: [String: Any] = ["chat":"peer@lid", "id":"[\"\",\"\(stanza)\"]", "stanza":stanza, "sender":"", "timestamp":10, "outgoing":true, "text":"rejected", "kind":"text", "edited":false, "deleted":false, "details":["pollOptions":[],"receipts":[],"rejection":["code":"479","timestamp":20]]]
      let message = try JSONDecoder().decode(WhatsAppMessage.self, from: JSONSerialization.data(withJSONObject: payload))
      let entry = WhatsAppJournalEntry(sequence: early ? 1 : 2, message: message, history: true, observed: 20)
      if early { try await b.ingest([entry], accountID: account) }
      try await a.settleOutgoing(id: draft.id, accountID: account, attemptID: attempt, outcome: .sent, stanza: stanza)
      if !early { try await b.ingest([entry], accountID: account) }
      let value = try await b.outgoing(id: draft.id, accountID: account)
      XCTAssertEqual(value.state.rawValue, "rejected", "wire success cannot hide source server rejection")
    }
  }
  func testPrepareIsDurableAccountScopedAndClaimedExactlyOnce() async throws {
    let (a, b, id) = try await repositories()
    let draft = try await a.prepareOutgoing(
      accountID: id, chat: "peer@lid",
      content: .init(text: "durable text", replyTo: "quoted", files: [UUID()]))
    let restored = try await b.outgoing(accountID: id)
    XCTAssertEqual(restored, [draft])
    XCTAssertEqual(restored[0].content.replyTo, "quoted")
    let empty = try await b.outgoing(accountID: UUID())
    XCTAssertTrue(empty.isEmpty)
    let attempt = try await a.claimOutgoing(id: draft.id, accountID: id)
    XCTAssertEqual(attempt.state, .dispatching)
    XCTAssertNotNil(attempt.attemptID)
    do {
      _ = try await b.claimOutgoing(id: draft.id, accountID: id)
      XCTFail("Already admitted")
    } catch {}
    do {
      try await b.resolveOutgoing(id: draft.id, accountID: id, sent: false)
      XCTFail("Live owner cannot be resolved")
    } catch {}
    do {
      try await a.settleOutgoing(id: draft.id, accountID: id, attemptID: UUID(), outcome: .sent)
      XCTFail("Wrong attempt")
    } catch {}
    do {
      try await b.resolveOutgoing(id: draft.id, accountID: id, sent: false)
      XCTFail("A stale callback must not release the live owner's lock")
    } catch {}
    try await a.settleOutgoing(
      id: draft.id, accountID: id, attemptID: try XCTUnwrap(attempt.attemptID), outcome: .unknown)
    let unknown = try await b.outgoing(accountID: id)
    XCTAssertEqual(unknown[0].state, .unknown)
    do {
      _ = try await b.claimOutgoing(id: draft.id, accountID: id)
      XCTFail("Unknown must never replay")
    } catch {}
  }
  func testExplicitResolutionRejectsLateCompletionAndDoesNotReplay() async throws {
    let (a, b, id) = try await repositories()
    let draft = try await a.prepareOutgoing(
      accountID: id, chat: "peer@lid", content: .init(text: "one"))
    let attempt = try await a.claimOutgoing(id: draft.id, accountID: id)
    let attemptID = try XCTUnwrap(attempt.attemptID)
    try await a.settleOutgoing(id: draft.id, accountID: id, attemptID: attemptID, outcome: .unknown)
    try await b.resolveOutgoing(id: draft.id, accountID: id, sent: false)
    do {
      try await a.settleOutgoing(id: draft.id, accountID: id, attemptID: attemptID, outcome: .sent)
      XCTFail("Late completion cannot undo explicit resolution")
    } catch {}
    let rows = try await b.outgoing(accountID: id)
    XCTAssertEqual(rows[0].state, .notSent)
    do {
      _ = try await a.claimOutgoing(id: draft.id, accountID: id)
      XCTFail("Retry requires a new explicit draft")
    } catch {}
    do {
      _ = try await a.prepareOutgoing(accountID: id, chat: "", content: .init(text: ""))
      XCTFail("Invalid draft")
    } catch {}
  }
}
