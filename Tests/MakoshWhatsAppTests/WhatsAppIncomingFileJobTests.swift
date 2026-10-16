import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppIncomingFileJobTests: XCTestCase {
  func testReservationsSurviveReopenAndCompletedRowsDoNotHidePendingWork() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let config = ContactWorkspaceConfiguration(
      connectionString: connection,
      schema: "qa_whatsapp_"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x78, count: 32) }
    let repo = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Jobs")
    try await repo.saveAccount(account)
    var remaining: WhatsAppIncomingFileJob?
    for n in 0..<35 {
      var message = WhatsAppMessage(
        chat: "peer@lid", id: "m-\(n)", stanza: "m-\(n)", sender: "peer@lid", timestamp: 10,
        outgoing: false, text: "", kind: "document", edited: false, deleted: false)
      message.details = .init()
      message.details?.resourceID = String(repeating: "a", count: 64)
      var job = try await repo.reserveIncomingFile(accountID: account.id, message: message)
      if n < 34 {
        job.state = "complete"
        try await repo.saveIncomingFileJob(job)
      } else {
        remaining = job
      }
    }
    let reopened = WhatsAppRepository(configuration: config, keyProvider: keys)
    let jobs = try await reopened.incomingFileJobs(accountID: account.id)
    XCTAssertEqual(jobs, [try XCTUnwrap(remaining)])
    let same = try await reopened.reserveIncomingFile(
      accountID: account.id, message: try XCTUnwrap(remaining).message)
    XCTAssertEqual(same.id, remaining?.id)
    var message = same.message
    message.id = "rebound"
    let changed = WhatsAppIncomingFileJob(id: same.id, accountID: same.accountID, message: message)
    do {
      try await reopened.saveIncomingFileJob(changed)
      XCTFail("Cannot rebind snapshot")
    } catch {}
  }
}

private actor SuspendedDownloadTransport: WhatsAppTransport {
  private(set) var requests = 0
  private var pending: [CheckedContinuation<Void, Never>] = []
  func release() { let values = pending; pending = []; for c in values { c.resume() } }
  func perform(chat: String, action: WhatsAppAction) async throws -> WhatsAppMutationResult {
    requests += 1
    await withCheckedContinuation { pending.append($0) }
    throw WhatsAppFailure.closed
  }
  func connect() {}
  func disconnect() {}
  func close() {}
  func status() -> WhatsAppConnectionStatus { .init() }
  func chats(before: WhatsAppCursor?) -> [WhatsAppChat] { [] }
  func journal() -> [WhatsAppJournalEntry] { [] }
  func acknowledge(_ sequence: Int64) {}
}
private extension WhatsAppWorker {
  func installFilesForFixture(_ value: WhatsAppFiles) { files = value }
  func ownsArchiveTask(_ account: UUID) -> Bool { archiveTasks[account] != nil }
}
extension WhatsAppIncomingFileJobTests {
  func testReconnectRevokesSuspendedArchiveOwnershipAndRunsNextJob() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], let storage = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("PG/S3 required") }
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x74, count: 32) }
    let repo = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Reconnect")
    try await repo.saveAccount(account)
    let spool = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let files = WhatsAppFiles(configuration: config, storageFile: URL(fileURLWithPath: storage), spool: spool, repository: repo, keyProvider: keys)
    let transport = SuspendedDownloadTransport()
    let worker = WhatsAppWorker(factory: { _ in transport }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    await worker.installFilesForFixture(files)
    try await worker.connect(accountID: account.id)
    var message = WhatsAppMessage(chat: "peer@lid", id: "first", stanza: "first", sender: "peer@lid", timestamp: 10, outgoing: false, text: "", kind: "document", edited: false, deleted: false)
    message.details = .init(); message.details?.resourceID = String(repeating: "a", count: 64)
    _ = try await repo.reserveIncomingFile(accountID: account.id, message: message)
    await worker.kickIncomingFiles(account.id)
    for _ in 0..<100 { if await transport.requests > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
    let first = await transport.requests
    XCTAssertEqual(first, 1)
    try await worker.connect(accountID: account.id)
    await transport.release()
    for _ in 0..<20 { await Task.yield() }
    let retainedOwner = await worker.ownsArchiveTask(account.id)
    XCTAssertFalse(retainedOwner, "reconnect must release the old task slot")
    message.id = "second"; message.stanza = "second"
    _ = try await repo.reserveIncomingFile(accountID: account.id, message: message)
    await worker.kickIncomingFiles(account.id)
    for _ in 0..<100 { if await transport.requests > 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
    let second = await transport.requests
    XCTAssertGreaterThan(second, first)
    await worker.shutdown()
    await transport.release()
  }
}
