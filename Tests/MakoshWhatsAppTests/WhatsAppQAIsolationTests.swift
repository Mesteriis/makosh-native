import Foundation
import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppQAIsolationTests: XCTestCase {
  private func fixture(
    schema: String = "qa_whatsapp_test", archive: String? = "qa_whatsapp_archive_test",
    dsn: String = "host=127.0.0.1 hostaddr=127.0.0.1 dbname=fixture user=synthetic",
    endpoint: String = "http://127.0.0.1:9000"
  ) throws -> (URL, ContactWorkspaceConfiguration, [String]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wa-qa-" + UUID().uuidString
    ).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let config = ContactWorkspaceConfiguration(
      connectionString: dsn, schema: schema, archiveSchema: archive)
    var values: [String: Any] = ["connectionString": dsn, "schema": schema]
    if let archive { values["archiveSchema"] = archive }
    try JSONSerialization.data(withJSONObject: values.compactMapValues { $0 is NSNull ? nil : $0 })
      .write(to: root.appendingPathComponent("database.json"))
    let s3 = try S3ObjectStoreConfiguration(
      endpoint: endpoint, region: "local", bucket: "qa-whatsapp", accessKeyID: "synthetic",
      secretAccessKey: "synthetic")
    try JSONEncoder().encode(s3).write(to: root.appendingPathComponent("storage.json"))
    try Data("makosh-whatsapp-synthetic-v1".utf8).write(
      to: root.appendingPathComponent(".makosh-whatsapp-qa"))
    for name in ["database.json", "storage.json", ".makosh-whatsapp-qa"] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path)
    }
    return (
      root, config,
      [
        "qa", "--whatsapp-synthetic-preview", "--database-config",
        root.appendingPathComponent("database.json").path, "--storage-config",
        root.appendingPathComponent("storage.json").path, "--whatsapp-qa-root", root.path,
      ]
    )
  }
  func testQARejectsEitherUnprefixedSchemaAndRealBoundaries() throws {
    let valid = try fixture()
    defer { try? FileManager.default.removeItem(at: valid.0) }
    XCTAssertNoThrow(try WhatsAppQAIsolation.validate(configuration: valid.1, arguments: valid.2))
    for (schema, archive, dsn, endpoint) in [
      ("makosh", "qa_whatsapp_a", "host=127.0.0.1 hostaddr=127.0.0.1", "http://127.0.0.1:9000"),
      ("qa_whatsapp_a", "makosh", "host=127.0.0.1 hostaddr=127.0.0.1", "http://127.0.0.1:9000"),
      (
        "qa_whatsapp_a", "qa_whatsapp_b", "host=203.0.113.1 hostaddr=203.0.113.1",
        "http://127.0.0.1:9000"
      ), ("qa_whatsapp_a", "qa_whatsapp_b", "host=localhost", "http://127.0.0.1:9000"),
      (
        "qa_whatsapp_a", "qa_whatsapp_b", "host=127.0.0.1 hostaddr=127.0.0.1 service=private",
        "http://127.0.0.1:9000"
      ),
      (
        "qa_whatsapp_a", "qa_whatsapp_b", "host=127.0.0.1 hostaddr=127.0.0.1",
        "https://example.test"
      ),
    ] {
      let f = try fixture(schema: schema, archive: archive, dsn: dsn, endpoint: endpoint)
      defer { try? FileManager.default.removeItem(at: f.0) }
      XCTAssertThrowsError(try WhatsAppQAIsolation.validate(configuration: f.1, arguments: f.2))
    }
  }
  func testMarkedBundleRequiresExplicitConfigurationBeforeIO() throws {
    XCTAssertFalse(WhatsAppQAIsolation.permitsNormalLaunch(marker: "whatsapp", arguments: ["app"]))
    XCTAssertTrue(WhatsAppQAIsolation.permitsNormalLaunch(marker: nil, arguments: ["app"]))
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.0) }
    for args in [
      ["qa"], f.2 + ["--telegram-synthetic-preview"], f.2 + ["--storage-config", "/private/other"],
      Array(f.2.dropLast(2)),
    ] {
      XCTAssertThrowsError(try WhatsAppQAIsolation.validate(configuration: f.1, arguments: args))
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.0.path)
    XCTAssertThrowsError(try WhatsAppQAIsolation.validate(configuration: f.1, arguments: f.2))
  }
}
extension WhatsAppQAIsolationTests {
  func testOwnedFixturesRestartRetainsUnknownAndNeverClaimsProviderConnection() async throws {
    guard var connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PostgreSQL required")
    }
    if var parts = URLComponents(string: connection),
      ["postgres", "postgresql"].contains(parts.scheme ?? "")
    {
      var items = parts.queryItems ?? []
      items.removeAll { $0.name == "hostaddr" }
      items.append(.init(name: "hostaddr", value: parts.host == "::1" ? "::1" : "127.0.0.1"))
      parts.queryItems = items
      connection = parts.string!
    } else {
      connection += " hostaddr=127.0.0.1"
    }
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let f = try fixture(
      schema: "qa_whatsapp_" + suffix, archive: "qa_whatsapp_archive_" + suffix, dsn: connection,
      endpoint: "http://127.0.0.1:1")
    defer { try? FileManager.default.removeItem(at: f.0) }
    let service = try await WhatsAppWorker.openQuestionsQA(configuration: f.1, arguments: f.2)
    let accounts = try await service.load(configuration: f.1)
    XCTAssertEqual(accounts.count, 2)
    let first = try XCTUnwrap(accounts.first)
    let snapshot = try await service.snapshot(accountID: first.id)
    XCTAssertFalse(snapshot.status.linked)
    let messages = try await service.messages(
      accountID: first.id, chat: "test-alex@lid", before: nil)
    XCTAssertTrue(messages.contains { $0.id == "qa-contact" })
    XCTAssertTrue(messages.contains { $0.id == "qa-poll" })
    let avatar = try await service.avatar(accountID: first.id, jid: "test-alex@lid", refresh: false)
    XCTAssertNotNil(avatar)
    let info = try await service.info(
      accountID: first.id, chat: "test-team@g.us", operation: .groupInfo)
    XCTAssertEqual(info.members?.count, 32)
    XCTAssertEqual(info.members?.filter(\.me).count, 1)
    let rows = try await service.outgoing(accountID: first.id)
    XCTAssertEqual(rows.count, 3)
    XCTAssertEqual(rows.filter { $0.state == .unknown }.count, 1)
    let photo = try await service.capturePhoto(
      accountID: first.id, chat: "test-alex@lid",
      file: f.0.appendingPathComponent("fixtures/photo.png"))
    XCTAssertTrue(photo.sourceReady)
    await service.shutdown()
    let restored = try await WhatsAppWorker.openQuestionsQA(configuration: f.1, arguments: f.2)
    let again = try await restored.outgoing(accountID: first.id)
    XCTAssertEqual(again.map(\.id), rows.map(\.id))
    XCTAssertEqual(again.filter { $0.state == .unknown }.count, 1)
    await restored.shutdown()
  }
}
