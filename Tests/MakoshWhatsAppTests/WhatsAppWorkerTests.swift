import MakoshCore
import XCTest

@testable import MakoshWhatsApp

private actor JournalTransport: WhatsAppTransport {
  var entries: [WhatsAppJournalEntry]
  var acknowledgements: [Int64] = []
  init(invalid: Bool) {
    entries = [
      .init(
        sequence: invalid ? 0 : 1,
        message: .init(
          chat: "peer@lid", id: "id", stanza: "id", sender: "peer@lid", timestamp: 10,
          outgoing: false, text: "durable first", kind: "text", edited: false, deleted: false),
        history: false, observed: 100)
    ]
  }
  func connect() {}
  func disconnect() {}
  func close() {}
  func status() -> WhatsAppConnectionStatus {
    var status = WhatsAppConnectionStatus()
    status.state = "connected"
    status.revision = 1
    return status
  }
  func chats(before: WhatsAppCursor?) -> [WhatsAppChat] {
    [.init(id: "peer@lid", name: "Test peer", timestamp: 10)]
  }
  func journal() -> [WhatsAppJournalEntry] { entries }
  func acknowledge(_ sequence: Int64) {
    acknowledgements.append(sequence)
    entries.removeAll { $0.sequence <= sequence }
  }
}

final class WhatsAppWorkerTests: XCTestCase {
  private func configuration() throws -> ContactWorkspaceConfiguration {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PostgreSQL integration configuration required")
    }
    return .init(
      connectionString: connection,
      schema: "qa_whatsapp_"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
  }
  func testArchiveFailureDoesNotAcknowledgeOrSuppressAnotherAccount() async throws {
    let config = try configuration()
    let bad = JournalTransport(invalid: true)
    let good = JournalTransport(invalid: false)
    let badID = UUID()
    let goodID = UUID()
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x75, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    try await repository.saveAccount(.init(id: badID, name: "Bad"))
    try await repository.saveAccount(.init(id: goodID, name: "Good"))
    let worker = WhatsAppWorker(factory: { id in id == badID ? bad : good }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    try await worker.connect(accountID: badID)
    try await worker.connect(accountID: goodID)
    let snapshot = try await worker.snapshot(accountID: goodID)
    XCTAssertEqual(snapshot.status.state, "connected")
    XCTAssertEqual(snapshot.chats.count, 1)
    let badAcks = await bad.acknowledgements
    let goodAcks = await good.acknowledgements
    XCTAssertTrue(badAcks.isEmpty)
    XCTAssertEqual(goodAcks, [1])
    let saved = try await repository.messages(accountID: goodID, chat: "peer@lid", before: nil)
    XCTAssertEqual(saved.first?.text, "durable first")
    let failed = try await worker.snapshot(accountID: badID)
    XCTAssertEqual(failed.status.state, "failed")
    await worker.shutdown()
  }
  func testSyntheticModeRejectsBothProductionSchemaAndArchiveSchema() async throws {
    let worker = WhatsAppWorker(synthetic: true)
    for config in [
      ContactWorkspaceConfiguration(connectionString: "never connect", schema: "makosh"),
      ContactWorkspaceConfiguration(
        connectionString: "never connect", schema: "qa_whatsapp_allowed", archiveSchema: "makosh"),
    ] {
      do {
        _ = try await worker.load(configuration: config)
        XCTFail("Must fail before SQL or Keychain")
      } catch { XCTAssertEqual(error as? WhatsAppFailure, .invalid) }
    }
  }
}

private actor ResumeTransport: WhatsAppTransport {
  private(set) var commands = 0
  func connect() {}
  func disconnect() {}
  func close() {}
  func status() -> WhatsAppConnectionStatus {
    var s = WhatsAppConnectionStatus()
    s.state = "connected"
    return s
  }
  func chats(before: WhatsAppCursor?) -> [WhatsAppChat] { [] }
  func journal() -> [WhatsAppJournalEntry] { [] }
  func acknowledge(_ sequence: Int64) {}
  func perform(chat: String, action: WhatsAppAction) -> WhatsAppMutationResult {
    commands += 1
    return .init(stanza: "MK" + action.attempt.replacingOccurrences(of: "-", with: "").uppercased())
  }
}
extension WhatsAppWorkerTests {
  func testExplicitResumeUsesOriginalPreparedRowAndNeverReplaysSettledAttempt() async throws {
    let config = try configuration()
    let transport = ResumeTransport()
    let id = UUID()
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x76, count: 32) }
    let repo = WhatsAppRepository(configuration: config, keyProvider: keys)
    try await repo.saveAccount(.init(id: id, name: "Resume"))
    let draft = try await repo.prepareOutgoing(
      accountID: id, chat: "peer@lid", content: .init(text: "prepared before crash"))
    let worker = WhatsAppWorker(factory: { _ in transport }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    try await worker.connect(accountID: id)
    let resumed = try await worker.resumeOutgoing(accountID: id, id: draft.id)
    XCTAssertEqual(resumed.id, draft.id)
    XCTAssertEqual(resumed.state, .sent)
    do {
      _ = try await worker.resumeOutgoing(accountID: id, id: draft.id)
      XCTFail("Must not replay")
    } catch {}
    let count = await transport.commands
    XCTAssertEqual(count, 1)
    let rows = try await repo.outgoing(accountID: id)
    XCTAssertEqual(rows.count, 1)
    await worker.shutdown()
  }
}
