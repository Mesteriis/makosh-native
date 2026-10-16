import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppRetentionTests: XCTestCase {
  func testPermanentArchivePreservesExactMediaVersionsAndRichPayload() async throws {
    let repository = WhatsAppRepository(configuration: try configuration(), keyProvider: { _, _ in Data(repeating: 0x6c, count: 32) })
    let account = WhatsAppAccount(name: "Archive resource")
    try await repository.saveAccount(account)
    var message = WhatsAppMessage(chat: "peer@lid", id: "[\"peer@lid\",\"stanza\"]", stanza: "stanza", sender: "peer@lid", timestamp: 10, outgoing: false, text: "caption", kind: "document", edited: false, deleted: false)
    message.details = .init()
    message.details?.resourceID = String(repeating: "a", count: 64)
    message.details?.name = "original.txt"
    message.details?.size = 123
    message.details?.contactVcard = "BEGIN:VCARD"
    try await repository.ingest([.init(sequence: 1, message: message, history: false, observed: 10)], accountID: account.id)
    message.details?.resourceID = String(repeating: "b", count: 64)
    message.details?.name = "replacement.txt"
    try await repository.ingest([.init(sequence: 2, message: message, history: false, observed: 20)], accountID: account.id)
    let rows = try await repository.archivePage(accountID: account.id, chat: message.chat, before: nil)
    let items = rows.compactMap { row -> MessageArchiveAttachment? in
      guard case .message(let content) = row.observation.event else { return nil }
      return content.attachments.first
    }
    XCTAssertEqual(items.map(\.id), [String(repeating: "b", count: 64), String(repeating: "a", count: 64)])
    XCTAssertEqual(items.last?.name, "original.txt")
    XCTAssertEqual(items.last?.size, 123)
    let rich = try JSONDecoder().decode(WhatsAppMessage.self, from: XCTUnwrap(rows.last?.observation.sourcePayload))
    XCTAssertEqual(rich.details?.contactVcard, "BEGIN:VCARD")
  }
  func testReceiptCannotRegressAfterLateHistoryOrAccountReplay() async throws {
    let repository = WhatsAppRepository(
      configuration: try configuration(), keyProvider: { _, _ in Data(repeating: 0x6b, count: 32) })
    let account = WhatsAppAccount(name: "Receipts")
    try await repository.saveAccount(account)
    var message = WhatsAppMessage(
      chat: "peer@lid", id: "one", stanza: "one", sender: "", timestamp: 10, outgoing: true,
      text: "document", kind: "document", edited: false, deleted: false)
    message.delivery = 3
    try await repository.ingest(
      [.init(sequence: 1, message: message, history: false, observed: 20)], accountID: account.id)
    message.delivery = 1
    try await repository.ingest(
      [.init(sequence: 2, message: message, history: true, observed: 21)], accountID: account.id)
    let page = try await repository.messages(accountID: account.id, chat: "peer@lid", before: nil)
    XCTAssertEqual(page.first?.delivery, 3)
  }
  func configuration() throws -> ContactWorkspaceConfiguration {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PostgreSQL integration configuration is required")
    }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    return .init(connectionString: connection, schema: schema, archiveSchema: schema)
  }
  func testReplayRetainsVersionsAndAccountIsolation() async throws {
    let config = try configuration()
    let key: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x67, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: key)
    let first = WhatsAppAccount(id: UUID(), name: "First")
    let second = WhatsAppAccount(id: UUID(), name: "Second")
    try await repository.saveAccount(first)
    try await repository.saveAccount(second)
    var original = WhatsAppMessage(
      chat: "peer@lid", id: "[\"peer@lid\",\"id\"]", stanza: "id", sender: "peer@lid",
      timestamp: 10, outgoing: false, text: "original retained text", kind: "text", edited: false,
      deleted: false)
    let initial = WhatsAppJournalEntry(
      sequence: 1, message: original, history: false, observed: 100)
    try await repository.ingest([initial], accountID: first.id)
    try await repository.ingest([initial], accountID: first.id)
    original.text = "edited retained text"
    original.edited = true
    try await repository.ingest(
      [.init(sequence: 2, message: original, history: false, observed: 110)], accountID: first.id)
    original.deleted = true
    try await repository.ingest(
      [.init(sequence: 3, message: original, history: false, observed: 120)], accountID: first.id)
    let page = try await repository.messages(accountID: first.id, chat: "peer@lid", before: nil)
    XCTAssertEqual(page.count, 1)
    XCTAssertEqual(page[0].text, "edited retained text")
    XCTAssertTrue(page[0].deleted)
    let other = try await repository.messages(accountID: second.id, chat: "peer@lid", before: nil)
    XCTAssertTrue(other.isEmpty)
    let versions = try await repository.versions(accountID: first.id, chat: "peer@lid")
    XCTAssertEqual(versions.count, 3)
    let reopened = WhatsAppRepository(configuration: config, keyProvider: key)
    let restored = try await reopened.messages(accountID: first.id, chat: "peer@lid", before: nil)
    XCTAssertEqual(restored, page)
    let offlineChats = try await reopened.chats(accountID: first.id)
    XCTAssertEqual(
      offlineChats.map(\.id), ["peer@lid"],
      "Acknowledged messages must be discoverable without a later native chat refresh")
    let accounts = try await reopened.accounts()
    XCTAssertEqual(accounts.count, 2)
    var changed = initial
    changed.message.text = "rebound sequence"
    do {
      try await reopened.ingest([changed], accountID: first.id)
      XCTFail("Receipt identity cannot be rebound")
    } catch {}
  }
  func testHistoricalEditAndDeletionAdvanceWithoutStaleReplay() async throws {
    let repository = WhatsAppRepository(
      configuration: try configuration(), keyProvider: { _, _ in Data(repeating: 0x69, count: 32) })
    let account = WhatsAppAccount(name: "History")
    try await repository.saveAccount(account)
    var message = WhatsAppMessage(
      chat: "peer@lid", id: "one", stanza: "one", sender: "peer@lid", timestamp: 10,
      outgoing: false, text: "original", kind: "text", edited: false, deleted: false)
    message.versionTimestamp = 10_000
    try await repository.ingest(
      [.init(sequence: 1, message: message, history: true, observed: 10)], accountID: account.id)
    message.edited = true
    message.text = "historical edit"
    message.versionTimestamp = 20_000
    try await repository.ingest(
      [.init(sequence: 2, message: message, history: true, observed: 20)], accountID: account.id)
    message.deleted = true
    message.versionTimestamp = 30_000
    try await repository.ingest(
      [.init(sequence: 3, message: message, history: true, observed: 30)], accountID: account.id)
    message.edited = false
    message.deleted = false
    message.text = "stale original"
    message.versionTimestamp = 10_000
    try await repository.ingest(
      [.init(sequence: 4, message: message, history: true, observed: 40)], accountID: account.id)
    let page = try await repository.messages(accountID: account.id, chat: "peer@lid", before: nil)
    XCTAssertEqual(page.first?.text, "historical edit")
    XCTAssertEqual(page.first?.deleted, true)
    let versions = try await repository.versions(accountID: account.id, chat: "peer@lid")
    XCTAssertEqual(versions.count, 4)
  }
  func testProtocolEnvelopeIsRetainedWithoutPhantomChat() async throws {
    let repository = WhatsAppRepository(
      configuration: try configuration(), keyProvider: { _, _ in Data(repeating: 0x6a, count: 32) })
    let account = WhatsAppAccount(name: "Protocol")
    try await repository.saveAccount(account)
    let message = WhatsAppMessage(
      chat: "self@lid", id: "control", stanza: "control", sender: "", timestamp: 10, outgoing: true,
      text: "", kind: "protocol", edited: false, deleted: false)
    try await repository.ingest(
      [.init(sequence: 1, message: message, history: false, observed: 10)], accountID: account.id)
    let chats = try await repository.chats(accountID: account.id)
    let messages = try await repository.messages(
      accountID: account.id, chat: "self@lid", before: nil)
    XCTAssertTrue(chats.isEmpty)
    XCTAssertTrue(messages.isEmpty)
    let retained = try await repository.versions(accountID: account.id, chat: "self@lid")
    XCTAssertEqual(retained.count, 1)
  }
  func testPagingTimestampTiesAndHistoryCannotOverwriteNewerVersion() async throws {
    let repository = WhatsAppRepository(
      configuration: try configuration(), keyProvider: { _, _ in Data(repeating: 0x68, count: 32) })
    let account = WhatsAppAccount(id: UUID(), name: "Paging")
    try await repository.saveAccount(account)
    var entries: [WhatsAppJournalEntry] = []
    for n in 1...65 {
      let message = WhatsAppMessage(
        chat: "same@lid", id: "id-\(n)", stanza: "\(n)", sender: "same@lid", timestamp: 10,
        outgoing: false, text: "message \(n)", kind: "text", edited: false, deleted: false)
      entries.append(.init(sequence: Int64(n), message: message, history: true, observed: 100))
    }
    try await repository.ingest(entries, accountID: account.id)
    let first = try await repository.messages(accountID: account.id, chat: "same@lid", before: nil)
    let second = try await repository.messages(
      accountID: account.id, chat: "same@lid", before: first.last?.cursor)
    XCTAssertEqual(first.count, 50)
    XCTAssertEqual(second.count, 15)
    XCTAssertEqual(Set((first + second).map(\.id)).count, 65)
    var edit = entries[0]
    edit.sequence = 66
    edit.history = false
    edit.message.edited = true
    edit.message.text = "new edit"
    try await repository.ingest([edit], accountID: account.id)
    var history = entries[0]
    history.sequence = 67
    try await repository.ingest([history], accountID: account.id)
    let all = try await repository.messages(
      accountID: account.id, chat: "same@lid", before: nil, limit: 100)
    XCTAssertEqual(all.first(where: { $0.id == edit.message.id })?.text, "new edit")
  }
}
