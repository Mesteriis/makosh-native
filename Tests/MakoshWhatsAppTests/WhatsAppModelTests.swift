import MakoshCore
import MakoshWhatsApp
import XCTest

@testable import MakoshApp

private actor SelectionService: WhatsAppServing {
  let first = WhatsAppAccount(name: "First"), second = WhatsAppAccount(name: "Second")
  private var pending: CheckedContinuation<[WhatsAppMessage], any Error>?
  var waiting: Bool { pending != nil }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [first, second] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    .init(
      accountID: accountID, status: .init(),
      chats: [.init(id: accountID.uuidString, name: "Selected")])
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) async throws
    -> [WhatsAppMessage]
  {
    if accountID == first.id { return try await withCheckedThrowingContinuation { pending = $0 } }
    return [
      .init(
        chat: chat, id: "second", stanza: "second", sender: "", timestamp: 2, outgoing: false,
        text: "second account", kind: "text", edited: false, deleted: false)
    ]
  }
  func complete() {
    pending?.resume(returning: [
      .init(
        chat: first.id.uuidString, id: "stale", stanza: "stale", sender: "", timestamp: 1,
        outgoing: false, text: "stale first account", kind: "text", edited: false, deleted: false)
    ])
    pending = nil
  }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func shutdown() {}
}

private actor BurstService: WhatsAppServing {
  let account = WhatsAppAccount(name: "Burst")
  var total = 50
  func burst() { total = 110 }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [account] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    .init(accountID: accountID, status: .init(), chats: [.init(id: "chat", name: "Burst")])
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) -> [WhatsAppMessage] {
    (1...total).reversed().filter { Int64($0) < (before?.timestamp ?? .max) }.prefix(50).map { n in
      .init(
        chat: chat, id: String(n), stanza: String(n), sender: "peer", timestamp: Int64(n),
        outgoing: false, text: String(n), kind: "text", edited: false, deleted: false)
    }
  }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func shutdown() {}
}

private actor DelayedRestoreService: WhatsAppServing {
  let account = WhatsAppAccount(name: "Review restoration")
  var pause: CheckedContinuation<Void, Never>?
  var requests: [String] = []
  func waiting() -> Bool { pause != nil }
  func release() {
    pause?.resume()
    pause = nil
  }
  func composeDraft(accountID: UUID, chat: String) async -> WhatsAppComposeDraft? {
    if chat == "a@lid" { await withCheckedContinuation { pause = $0 } }
    return nil
  }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [account] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    .init(accountID: accountID, status: .init(), chats: [])
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) -> [WhatsAppMessage] {
    requests.append(chat)
    return []
  }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func shutdown() {}
}
@MainActor final class WhatsAppModelTests: XCTestCase {
  func testLateRestoreCannotRebindActionsOrBlockCurrentHistory() async throws {
    let service = DelayedRestoreService()
    let model = WhatsAppWorkspaceModel(worker: service, polling: false)
    await model.load(configuration: .init(connectionString: "synthetic stub"))
    let account = await service.account
    let old = Task { await model.selectChat("a@lid") }
    for _ in 0..<100 where !(await service.waiting()) {
      try await Task.sleep(for: .milliseconds(2))
    }
    let held = await service.waiting()
    XCTAssertTrue(held)
    await model.selectChat("b@lid")
    await service.release()
    await old.value
    XCTAssertTrue(model.actions.contextMatches(account: account.id, chat: "b@lid"))
    XCTAssertFalse(model.historyBusy)
    await model.refresh()
    let requests = await service.requests
    XCTAssertEqual(requests, ["b@lid", "b@lid"])
  }

  func testBurstRefreshKeepsEveryMessageReachable() async throws {
    let service = BurstService()
    let actual = WhatsAppWorkspaceModel(worker: service, polling: false)
    await actual.load(configuration: .init(connectionString: "synthetic stub"))
    await actual.selectChat("chat")
    await service.burst()
    await actual.refresh()
    for _ in 0..<5 { if actual.hasOlder { await actual.loadOlder() } }
    XCTAssertEqual(Set(actual.messages.map(\.id)), Set((1...110).map(String.init)))
  }
  func testLateHistoryCannotCrossAccountSelection() async throws {
    let service = SelectionService()
    let model = WhatsAppWorkspaceModel(worker: service, polling: false)
    await model.load(configuration: .init(connectionString: "synthetic stub"))
    let first = service.first
    let second = service.second
    await model.selectAccount(first.id)
    let old = Task { await model.selectChat(first.id.uuidString) }
    for _ in 0..<100 {
      if await service.waiting { break }
      await Task.yield()
    }
    let waiting = await service.waiting
    XCTAssertTrue(waiting)
    await model.selectAccount(second.id)
    await model.selectChat(second.id.uuidString)
    await service.complete()
    await old.value
    XCTAssertEqual(model.selectedAccountID, second.id)
    XCTAssertEqual(model.messages.map(\.id), ["second"])
  }
}
