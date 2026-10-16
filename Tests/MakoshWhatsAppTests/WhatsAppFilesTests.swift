import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppFilesTests: XCTestCase {
  func testRemoteDotFilenameCannotEscapeThePrivateLeaseDirectory() async throws {
    let config = ContactWorkspaceConfiguration(
      connectionString: "never connect", schema: "qa_whatsapp_lease")
    let repository = WhatsAppRepository(configuration: config)
    let service = WhatsAppFiles(
      configuration: config, storageFile: URL(fileURLWithPath: "/missing"),
      spool: URL(fileURLWithPath: "/missing"), repository: repository)
    let lease = try await service.makeLease(name: "..")
    let normalized = lease.url.standardizedFileURL
    defer { lease.remove() }
    XCTAssertEqual(normalized.deletingLastPathComponent(), lease.directory.standardizedFileURL)
  }
  func testSyntheticAdmissionNeverClaimsDeliveryAndRetainsPreparedMetadata() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PostgreSQL required")
    }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let worker = WhatsAppWorker(synthetic: true)
    let accounts = try await worker.load(configuration: config)
    let account = try XCTUnwrap(accounts.first)
    let admitted = try await worker.send(
      accountID: account.id, chat: "test-alex@lid", content: .init(text: "synthetic admission"))
    XCTAssertEqual(admitted.state, .prepared)
    XCTAssertNil(admitted.attemptID)
    let snapshot = try await worker.snapshot(accountID: account.id)
    XCTAssertFalse(snapshot.status.linked)
    let outbox = try await worker.outgoing(accountID: account.id)
    XCTAssertEqual(outbox, [admitted])
    await worker.shutdown()
  }
  func testIncomingOffRefusesBeforeFileAccessAndOnArchivesExactResource() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"],
      let storage = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"]
    else { throw XCTSkip("PG/S3 required") }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x77, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Incoming")
    try await repository.saveAccount(account)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let service = WhatsAppFiles(
      configuration: config, storageFile: URL(fileURLWithPath: storage),
      spool: root.appendingPathComponent("queue"), repository: repository, keyProvider: keys)
    var message = WhatsAppMessage(
      chat: "peer@lid", id: "incoming", stanza: "incoming", sender: "peer@lid", timestamp: 10,
      outgoing: false, text: "", kind: "document", edited: false, deleted: false)
    message.details = .init()
    message.details?.name = "report.txt"
    message.details?.resourceID = String(repeating: "a", count: 64)
    try await service.setSaving(accountID: account.id, chat: message.chat, enabled: false)
    let missing = root.appendingPathComponent("missing")
    let refused = try await service.archiveIncoming(
      file: missing, accountID: account.id, message: message)
    XCTAssertNil(refused)
    try await service.setSaving(accountID: account.id, chat: message.chat, enabled: true)
    let bytes = Data("synthetic incoming resource".utf8)
    let source = root.appendingPathComponent("source")
    try bytes.write(to: source)
    let firstValue = try await service.archiveIncoming(
      file: source, accountID: account.id, message: message)
    let secondValue = try await service.archiveIncoming(
      file: source, accountID: account.id, message: message)
    let first = try XCTUnwrap(firstValue)
    let second = try XCTUnwrap(secondValue)
    XCTAssertEqual(first.id, second.id)
    XCTAssertEqual(first.state, .stored)
    try await service.setSaving(accountID: account.id, chat: message.chat, enabled: false)
    let retained = try await service.archived(accountID: account.id, message: message)
    XCTAssertEqual(retained, [first])
  }
  func testGroupOffUsesEncryptedLocalPreparationAndNeverPromotesIt() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"],
      let storage = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"]
    else { throw XCTSkip("PG/S3 required") }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x78, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Files")
    try await repository.saveAccount(account)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    let bytes = Data("PRIVATE_WHATSAPP_SYNTHETIC_FILE_\(UUID())".utf8)
    try bytes.write(to: source)
    let service = WhatsAppFiles(
      configuration: config, storageFile: URL(fileURLWithPath: storage),
      spool: root.appendingPathComponent("queue"), repository: repository, keyProvider: keys)
    let prepared = try await service.prepare(
      file: source, accountID: account.id, chat: "test@g.us", kind: "document", mime: "text/plain")
    let receipt = try XCTUnwrap(prepared.record)
    XCTAssertEqual(receipt.state, .local)
    let store = try S3ObjectStore(
      configuration: S3ConfigurationFile.read(URL(fileURLWithPath: storage)))
    let absent = try await store.head(key: receipt.objectKey)
    XCTAssertNil(absent)
    try await service.setSaving(accountID: account.id, chat: "test@g.us", enabled: true)
    let restored = try await service.prepared(
      id: prepared.id, accountID: account.id, chat: "test@g.us")
    XCTAssertEqual(restored.record?.state, .local)
    let stillAbsent = try await store.head(key: receipt.objectKey)
    XCTAssertNil(stillAbsent)
    let lease = try await service.open(restored)
    defer { lease.remove() }
    XCTAssertEqual(try Data(contentsOf: lease.url), bytes)
    do {
      _ = try await service.prepared(id: prepared.id, accountID: UUID(), chat: "test@g.us")
      XCTFail("Account isolation")
    } catch {}
    let envelopes = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("queue"), includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "envelope" }
    XCTAssertEqual(envelopes.count, 1)
    XCTAssertNil(try Data(contentsOf: envelopes[0]).range(of: bytes))
  }
}

private extension WhatsAppWorker {
  func installHistoricalFixtureFiles(_ value: WhatsAppFiles) { files = value }
}
extension WhatsAppFilesTests {
  func testHistoricalDownloadUsesIngestedArchiveResourceAfterReplacementWithS3Off() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"], let storage = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("PG/S3 required") }
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x73, count: 32) }
    let repo = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Historical resource")
    try await repo.saveAccount(account)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let files = WhatsAppFiles(configuration: config, storageFile: URL(fileURLWithPath: storage), spool: root.appendingPathComponent("spool"), repository: repo, keyProvider: keys)
    var message = WhatsAppMessage(chat: "peer@lid", id: "[\"peer@lid\",\"media\"]", stanza: "media", sender: "peer@lid", timestamp: 10, outgoing: false, text: "same caption", kind: "document", edited: false, deleted: false)
    message.details = .init()
    let source = root.appendingPathComponent("source")
    for (n, letter) in [(1,"a"),(2,"b")] {
      message.details?.resourceID = String(repeating: letter, count: 64)
      message.details?.name = "version-\(n).txt"
      try Data("version \(n)".utf8).write(to: source)
      try await repo.ingest([.init(sequence: Int64(n), message: message, history: false, observed: Int64(n))], accountID: account.id)
      _ = try await files.archiveIncoming(file: source, accountID: account.id, message: message)
    }
    try await files.setSaving(accountID: account.id, chat: message.chat, enabled: false)
    let rows = try await repo.archivePage(accountID: account.id, chat: message.chat, before: nil)
    let old = try XCTUnwrap(rows.last)
    guard case .message(let content) = old.observation.event else { return XCTFail("Retained body") }
    let item = try XCTUnwrap(content.attachments.first)
    let worker = WhatsAppWorker(factory: { _ in throw WhatsAppFailure.closed }, keyProvider: keys)
    _ = try await worker.load(configuration: config)
    await worker.installHistoricalFixtureFiles(files)
    let lease = try await worker.downloadVersion(accountID: account.id, chat: message.chat, id: message.id, resource: item.id, kind: item.kind, name: item.name)
    defer { lease.remove() }
    XCTAssertEqual(try Data(contentsOf: lease.url), Data("version 1".utf8))
    await worker.shutdown()
  }
}
