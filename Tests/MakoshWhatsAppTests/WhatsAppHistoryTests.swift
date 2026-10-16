import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppHistoryTests: XCTestCase {
  func testSearchReachesOlderPagesAndArchiveRetainsEveryVersion() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x72, count: 32) }
    let repository = WhatsAppRepository(configuration: config, keyProvider: keys)
    let account = WhatsAppAccount(name: "Search")
    try await repository.saveAccount(account)
    var entries: [WhatsAppJournalEntry] = []
    for n in 1...120 {
      let message = WhatsAppMessage(
        chat: "peer@lid", id: "m\(n)", stanza: "m\(n)", sender: "peer@lid", timestamp: Int64(n),
        outgoing: false, text: [5, 110].contains(n) ? "needle \(n)" : "body \(n)", kind: "text",
        edited: false, deleted: false)
      entries.append(.init(sequence: Int64(n), message: message, history: true, observed: Int64(n)))
    }
    try await repository.ingest(Array(entries.prefix(100)), accountID: account.id)
    try await repository.ingest(Array(entries.suffix(20)), accountID: account.id)
    let first = try await repository.search(
      accountID: account.id, chat: "peer@lid", query: "needle", filter: .all, before: nil, limit: 1)
    let second = try await repository.search(
      accountID: account.id, chat: "peer@lid", query: "needle", filter: .all, before: first.next,
      limit: 1)
    XCTAssertEqual(first.messages.map(\.id), ["m110"])
    XCTAssertEqual(second.messages.map(\.id), ["m5"])
    var edit = entries[4]
    edit.sequence = 121
    edit.observed = 121
    edit.message.edited = true
    edit.message.text = "changed"
    edit.message.versionTimestamp = 121000
    try await repository.ingest([edit], accountID: account.id)
    let archive = try await repository.archivePage(
      accountID: account.id, chat: "peer@lid", before: nil)
    let older = try await repository.archivePage(
      accountID: account.id, chat: "peer@lid", before: archive.last?.sequence)
    XCTAssertEqual(archive.count + older.count, 121)
    let versions = (archive + older).filter { $0.observation.identity.messageID == "m5" }
    XCTAssertEqual(versions.count, 2)
  }
}
