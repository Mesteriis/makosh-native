import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

@MainActor final class WhatsAppRichPresentationTests: XCTestCase {
  func testPollQuestionOnceButDifferentBodyRetained() {
    var message = waRichMessage(kind: "poll", text: "  Где встречаемся?\n")
    message.details = .init()
    message.details?.pollName = "Где встречаемся?"
    XCTAssertNil(WhatsAppMessagePresentation.make(message).bodyText)
    message.text = "Другие сведения от автора"
    XCTAssertEqual(WhatsAppMessagePresentation.make(message).bodyText, "Другие сведения от автора")
    message.details?.pollName = nil
    XCTAssertEqual(WhatsAppMessagePresentation.make(message).bodyText, "Другие сведения от автора")
  }

  func testDuplicatePollLabelsHaveDistinctIDs() {
    var message = waRichMessage(kind: "poll", text: "Вопрос")
    message.details = .init()
    message.details?.pollName = "Вопрос"
    message.details?.pollOptions = ["Да", "Да", "Нет"]
    let options = WhatsAppMessagePresentation.make(message).pollOptions
    XCTAssertEqual(options.map(\.label), ["Да", "Да", "Нет"])
    XCTAssertEqual(options.map(\.id), [0, 1, 2])
    XCTAssertEqual(Set(options.map(\.id)).count, 3)
  }

  func testStatusFilteredFromListCountsAndRecipientsButArchiveRetained() async throws {
    guard let connection = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else {
      throw XCTSkip("PG required")
    }
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let config = ContactWorkspaceConfiguration(
      connectionString: connection, schema: "qa_whatsapp_" + suffix,
      archiveSchema: "qa_whatsapp_archive_" + suffix)
    let repository = WhatsAppRepository(
      configuration: config, keyProvider: { _, _ in Data(repeating: 0x64, count: 32) })
    let account = WhatsAppAccount(name: "Presentation")
    try await repository.saveAccount(account)
    var status = waRichMessage(kind: "text", text: "Retained status")
    status.chat = "status@broadcast"
    try await repository.ingest(
      [.init(sequence: 1, message: status, history: true, observed: 1)], accountID: account.id)
    let archived = try await repository.archivePage(
      accountID: account.id, chat: "status@broadcast", before: nil)
    XCTAssertEqual(archived.count, 1)
    let values: [WhatsAppChat] = [
      .init(id: "status@broadcast", name: "status@broadcast", unread: 10),
      .init(id: "peer@lid", name: "Статусы", unread: 3),
      .init(id: "other@lid", name: "Другой", unread: 2),
    ]
    let service = WAPresentationService(account: account, chats: values)
    let model = WhatsAppWorkspaceModel(worker: service, polling: false)
    await model.load(configuration: .init(connectionString: "synthetic boundary"))
    XCTAssertEqual(model.chats.map(\.id), ["peer@lid", "other@lid"])
    XCTAssertEqual(model.chats.map(\.unread).reduce(0, +), 5)
    await model.selectChat("status@broadcast")
    XCTAssertNil(model.selectedChatID)
    let projected = WhatsAppChatListProjection.visible(values)
    XCTAssertEqual(projected.map(\.id), ["peer@lid", "other@lid"])
    let retained = try await repository.messages(
      accountID: account.id, chat: "status@broadcast", before: nil)
    XCTAssertEqual(retained.map(\.text), ["Retained status"])
  }
}

private actor WAPresentationService: WhatsAppServing {
  let account: WhatsAppAccount, chats: [WhatsAppChat]
  init(account: WhatsAppAccount, chats: [WhatsAppChat]) {
    self.account = account
    self.chats = chats
  }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [account] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    .init(accountID: accountID, status: .init(), chats: chats)
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) -> [WhatsAppMessage] { [] }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func shutdown() {}
}
