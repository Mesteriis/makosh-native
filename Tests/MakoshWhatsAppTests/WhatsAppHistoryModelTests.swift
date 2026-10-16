import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

private actor HistoryBoundary: WhatsAppServing {
  var response: CheckedContinuation<WhatsAppSearchPage, any Error>?
  var retained: [MessageArchiveRecord] = []
  func setRetained(_ rows: [MessageArchiveRecord]) { retained = rows }
  func archivePage(accountID: UUID, chat: String, before: Int64?) -> [MessageArchiveRecord] { retained }
  func waiting() -> Bool { response != nil }
  func finish() {
    response?.resume(
      returning: .init(
        messages: [
          .init(
            chat: "peer@lid", id: "old", stanza: "old", sender: "peer@lid", timestamp: 1,
            outgoing: false, text: "private old result", kind: "text", edited: false, deleted: false
          )
        ], next: nil))
    response = nil
  }
  func search(
    accountID: UUID, chat: String, query: String, filter: WhatsAppHistoryFilter,
    before: WhatsAppCursor?
  ) async throws -> WhatsAppSearchPage {
    try await withCheckedThrowingContinuation { response = $0 }
  }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    .init(accountID: accountID, status: .init(), chats: [])
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) -> [WhatsAppMessage] { [] }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func shutdown() {}
}
@MainActor final class WhatsAppHistoryModelTests: XCTestCase {
  func testClearingSearchRejectsItsLatePrivateResult() async {
    let worker = HistoryBoundary()
    let actual = WhatsAppHistoryModel(worker: worker, accountID: UUID(), chat: "peer@lid")
    let search = Task { await actual.search(query: "old", filter: .all) }
    for _ in 0..<100 {
      if await worker.waiting() { break }
      await Task.yield()
    }
    actual.clear()
    await worker.finish()
    await search.value
    XCTAssertTrue(actual.messages.isEmpty)
    XCTAssertFalse(actual.busy)
    XCTAssertFalse(actual.active)
  }
}

extension WhatsAppHistoryModelTests {
  func testRichArchiveProjectsImmutableSourceMetadataBeforePublication() async throws {
    let account = UUID(), observationID = UUID()
    var message = WhatsAppMessage(chat: "peer@lid", id: "m", stanza: "m", sender: "peer@lid", timestamp: 1, outgoing: false, text: "contact", kind: "contact", edited: false, deleted: false)
    message.details = .init(); message.details?.contactVcard = "BEGIN:VCARD"
    let row = MessageArchiveRecord(sequence: 1, observation: .init(id: observationID, identity: .init(service: "whatsapp", accountID: account.uuidString, conversationID: message.chat, messageID: message.id), source: .update, event: .message(.init(date: Date(), text: "contact", author: "peer", isOutgoing: false)), sourcePayload: try JSONEncoder().encode(message)))
    let worker = HistoryBoundary()
    await worker.setRetained([row])
    let model = WhatsAppArchiveModel(worker: worker, accountID: account, chat: message.chat)
    await model.more()
    XCTAssertEqual(model.rows, [row])
    XCTAssertEqual(model.richMessages[observationID]?.details?.contactVcard, "BEGIN:VCARD")
  }
}
