import MakoshCore
import XCTest

@testable import MakoshWhatsApp

final class WhatsAppNotificationTests: XCTestCase {
  private func repositories() async throws -> (WhatsAppRepository, WhatsAppRepository, UUID, UUID) {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PostgreSQL required")
    }
    let schema =
      "qa_whatsapp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(connectionString: connection, schema: schema)
    let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x7a, count: 32) }
    let a = WhatsAppRepository(configuration: config, keyProvider: keys)
    let b = WhatsAppRepository(configuration: config, keyProvider: keys)
    let first = UUID()
    let second = UUID()
    try await a.saveAccount(.init(id: first, name: "First"))
    try await a.saveAccount(.init(id: second, name: "Second"))
    return (a, b, first, second)
  }
  func testEncryptedPreferencesRestrictEachOtherAndKeepAccountsIndependent() async throws {
    let (a, b, first, second) = try await repositories()
    var global = WhatsAppNotificationRule()
    global.preview = false
    try await a.setNotificationRule(global, accountID: nil, chat: nil)
    var chat = WhatsAppNotificationRule()
    chat.show = false
    chat.sound = false
    try await a.setNotificationRule(chat, accountID: first, chat: "peer@lid")
    let one = try await b.notificationRule(accountID: first, chat: "peer@lid")
    let two = try await b.notificationRule(accountID: second, chat: "peer@lid")
    XCTAssertFalse(one.show)
    XCTAssertFalse(one.preview)
    XCTAssertFalse(one.sound)
    XCTAssertTrue(two.show)
    XCTAssertFalse(two.preview)
    XCTAssertTrue(two.sound)
  }
  func testHistoryMutedMessagesAndConsumedEventsNeverReplay() async throws {
    let (a, b, id, _) = try await repositories()
    let now = Int64(Date().timeIntervalSince1970)
    func entry(_ n: Int64, history: Bool) -> WhatsAppJournalEntry {
      var message = WhatsAppMessage(
        chat: "peer@lid", id: "message-\(n)", stanza: "message-\(n)", sender: "peer@lid",
        timestamp: now, outgoing: false, text: "incoming \(n)", kind: "text", edited: false,
        deleted: false)
      message.delivery = 0
      var entry = WhatsAppJournalEntry(
        sequence: n, message: message, history: history, observed: now)
      entry.notify = !history
      return entry
    }
    try await a.ingest([entry(1, history: true)], accountID: id)
    let history = try await a.claimNotifications(accountID: id)
    XCTAssertTrue(history.isEmpty)
    var muted = WhatsAppNotificationRule()
    muted.show = false
    try await a.setNotificationRule(muted, accountID: id, chat: "peer@lid")
    try await a.ingest([entry(2, history: false)], accountID: id)
    try await a.setNotificationRule(.init(), accountID: id, chat: "peer@lid")
    let suppressed = try await b.claimNotifications(accountID: id)
    XCTAssertTrue(suppressed.isEmpty)
    try await a.ingest([entry(3, history: false)], accountID: id)
    let first = try await b.claimNotifications(accountID: id)
    let second = try await a.claimNotifications(accountID: id)
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(first[0].messageID, "message-3")
    XCTAssertTrue(second.isEmpty)
    XCTAssertEqual(first[0].id.count, 64)
    XCTAssertFalse(first[0].id.contains("peer"))
  }
  func testServerMuteRestrictsLocalOverrides() async throws {
    let (a, _, id, _) = try await repositories()
    var chat = WhatsAppChat(id: "peer@lid", name: "Peer", unread: 1)
    chat.mutedUntil = -1
    try await a.saveChats([chat], accountID: id)
    let rule = try await a.notificationRule(accountID: id, chat: chat.id)
    XCTAssertFalse(rule.show)
  }
  func testOpaqueChatIDCannotAliasAccountPreferenceScope() async throws {
    let (a, b, id, _) = try await repositories()
    var chat = WhatsAppNotificationRule()
    chat.show = false
    try await a.setNotificationRule(chat, accountID: id, chat: "account")
    let account = try await b.savedNotificationRule(accountID: id, chat: nil)
    let other = try await b.notificationRule(accountID: id, chat: "peer@lid")
    XCTAssertTrue(account.show)
    XCTAssertTrue(other.show)
  }

}

extension WhatsAppNotificationTests {
  func testProtectedIncomingNeverPersistsNotificationPreview() async throws {
    let (a, _, id, _) = try await repositories()
    let now = Int64(Date().timeIntervalSince1970)
    try await a.saveChats([.init(id: "peer@lid", name: "Private person", unread: 1)], accountID: id)
    var m = WhatsAppMessage(
      chat: "peer@lid", id: "protected", stanza: "protected", sender: "peer@lid", timestamp: now,
      outgoing: false, text: "PRIVATE_VIEW_ONCE", kind: "image", edited: false, deleted: false)
    m.details = .init()
    m.details?.protected = true
    var e = WhatsAppJournalEntry(sequence: 1, message: m, history: false, observed: now)
    e.notify = true
    try await a.ingest([e], accountID: id)
    let events = try await a.claimNotifications(accountID: id)
    XCTAssertEqual(events.first?.title, "WhatsApp")
    XCTAssertEqual(events.first?.body, "Новое защищённое сообщение")
  }
}
