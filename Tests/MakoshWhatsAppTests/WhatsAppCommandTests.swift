import MakoshCore
import XCTest

@testable import MakoshWhatsApp

private actor SendingTransport: WhatsAppTransport {
  var attempts: [String] = []
  let losesReply: Bool
  let closesDuringRequest: Bool
  init(losesReply: Bool, closesDuringRequest: Bool = false) {
    self.losesReply = losesReply
    self.closesDuringRequest = closesDuringRequest
  }
  func connect() {}
  func disconnect() {}
  func close() {}
  func status() -> WhatsAppConnectionStatus {
    var status = WhatsAppConnectionStatus()
    status.state = "connected"
    return status
  }
  func chats(before: WhatsAppCursor?) -> [WhatsAppChat] { [] }
  func journal() -> [WhatsAppJournalEntry] { [] }
  func acknowledge(_ sequence: Int64) {}
  func perform(chat: String, action: WhatsAppAction) throws -> WhatsAppMutationResult {
    attempts.append(action.attempt)
    if closesDuringRequest { throw WhatsAppFailure.closed }
    if losesReply { throw WhatsAppFailure.protocolFailure }
    return .init(stanza: "TEST-STANZA")
  }
}
final class WhatsAppCommandTests: XCTestCase {
  func testClosingAfterDispatchCannotBeReportedAsKnownNotSent() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PostgreSQL required")
    }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x76, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Close during dispatch")
    try await repository.saveAccount(account)
    let transport = SendingTransport(losesReply: false, closesDuringRequest: true)
    let worker = WhatsAppWorker(factory: { _ in transport }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    try await worker.connect(accountID: account.id)
    do {
      _ = try await worker.send(
        accountID: account.id, chat: "peer@lid", content: .init(text: "may already be sent"))
      XCTFail("Lost owner")
    } catch {}
    let rows = try await repository.outgoing(accountID: account.id)
    XCTAssertEqual(rows.first?.state, .unknown)
    await worker.shutdown()
  }
  func testLostReplyPersistsUnknownAndRefreshNeverResends() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PostgreSQL required")
    }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x76, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Commands")
    try await repository.saveAccount(account)
    let transport = SendingTransport(losesReply: true)
    let worker = WhatsAppWorker(factory: { _ in transport }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    try await worker.connect(accountID: account.id)
    do {
      _ = try await worker.send(
        accountID: account.id, chat: "peer@lid", content: .init(text: "lost reply"))
      XCTFail("Result is uncertain")
    } catch {}
    let pending = try await repository.outgoing(accountID: account.id)
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending[0].state, .unknown)
    for _ in 0..<3 { _ = try await worker.snapshot(accountID: account.id) }
    let attempts = await transport.attempts
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(pending[0].attemptID?.uuidString.lowercased(), attempts[0])
    await worker.shutdown()
  }
}

private actor CallAdmissionTransport: WhatsAppTransport {
  private var first = true, waiting: CheckedContinuation<Void, Never>?
  private(set) var operations: [WhatsAppAction.Operation] = []
  func ready() -> Bool { waiting != nil }
  func release() {
    waiting?.resume()
    waiting = nil
  }
  func connect() {}
  func disconnect() {}
  func close() {}
  func status() async -> WhatsAppConnectionStatus {
    if first {
      first = false
      await withCheckedContinuation { waiting = $0 }
    }
    var s = WhatsAppConnectionStatus()
    s.state = "connected"
    return s
  }
  func chats(before: WhatsAppCursor?) -> [WhatsAppChat] { [] }
  func journal() -> [WhatsAppJournalEntry] { [] }
  func acknowledge(_ sequence: Int64) {}
  func perform(chat: String, action: WhatsAppAction) -> WhatsAppMutationResult {
    operations.append(action.op)
    return .init()
  }
}
extension WhatsAppCommandTests {
  func testEndBeforeDelayedStatusPreventsLateProtocolCallStart() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x75, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Call fence")
    try await repository.saveAccount(account)
    let transport = CallAdmissionTransport()
    let worker = WhatsAppWorker(factory: { _ in transport }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    try await worker.connect(accountID: account.id)
    let start = Task {
      try await worker.perform(accountID: account.id, chat: "peer@lid", action: .init(.callStart))
    }
    for _ in 0..<200 {
      if await transport.ready() { break }
      await Task.yield()
    }
    let ready = await transport.ready()
    XCTAssertTrue(ready)
    _ = try await worker.perform(accountID: account.id, chat: "peer@lid", action: .init(.callEnd))
    await transport.release()
    _ = try? await start.value
    let operations = await transport.operations
    XCTAssertEqual(operations, [.callEnd])
    await worker.shutdown()
  }
}

private extension WhatsAppRepository {
  func corruptOldOutboxFixture(_ id: UUID, account: UUID) throws {
    let db = try db()
    let token = db.token([account.uuidString, "outgoing", id.uuidString])
    _ = try db.query("UPDATE \(db.outboxTable) SET ciphertext='invalid-test-envelope' WHERE token=$1", [token])
  }
}
extension WhatsAppCommandTests {
  func testCompletionReadsOnlyItsExactAttemptInsteadOfLifetimeHistory() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PG required") }
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x72, count: 32) }
    let repo = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Exact completion")
    try await repo.saveAccount(account)
    let old = try await repo.prepareOutgoing(accountID: account.id, chat: "peer@lid", content: .init(text: "old"))
    try await repo.corruptOldOutboxFixture(old.id, account: account.id)
    let transport = SendingTransport(losesReply: false)
    let worker = WhatsAppWorker(factory: { _ in transport }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    try await worker.connect(accountID: account.id)
    let sent = try await worker.send(accountID: account.id, chat: "peer@lid", content: .init(text: "new"))
    XCTAssertEqual(sent.state, .sent)
    XCTAssertEqual(sent.content.text, "new")
    await worker.shutdown()
  }
}
