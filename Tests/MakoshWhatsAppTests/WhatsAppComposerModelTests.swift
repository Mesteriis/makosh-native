import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

private actor ComposerService: WhatsAppServing {
  let compose=WhatsAppComposeTestStore()
  func composeDraft(accountID:UUID,chat:String) async -> WhatsAppComposeDraft? { await compose.read(account:accountID,chat:chat) }
  func saveComposeDraft(_ draft:WhatsAppComposeDraft,expectedRevision:UInt64?) async throws -> WhatsAppComposeDraft { try await compose.save(draft,expected:expectedRevision) }

  let first = WhatsAppAccount(name: "First"), second = WhatsAppAccount(name: "Second")
  private var pending: [UUID: CheckedContinuation<WhatsAppOutgoing, any Error>] = [:]
  private var requests: [UUID: (String, WhatsAppOutgoingContent)] = [:]
  func waiting(_ account: UUID) -> Bool { pending[account] != nil }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [first, second] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    var status = WhatsAppConnectionStatus()
    status.state = "connected"
    return .init(accountID: accountID, status: status, chats: [.init(id: "peer@lid", name: "Peer")])
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) -> [WhatsAppMessage] { [] }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func shutdown() {}
  func outgoing(accountID: UUID) -> [WhatsAppOutgoing] { [] }
  func send(accountID: UUID, chat: String, content: WhatsAppOutgoingContent) async throws
    -> WhatsAppOutgoing
  {
    requests[accountID] = (chat, content)
    return try await withCheckedThrowingContinuation { pending[accountID] = $0 }
  }
  func complete(_ account: UUID) {
    guard let request = requests.removeValue(forKey: account),
      let continuation = pending.removeValue(forKey: account)
    else { return }
    continuation.resume(
      returning: .init(
        id: UUID(), accountID: account, chat: request.0, content: request.1, created: Date(),
        state: .sent))
  }
}
@MainActor final class WhatsAppComposerModelTests: XCTestCase {
  func testLateFirstSendDoesNotClearSecondDraftOrItsBusyState() async throws {
    let service = ComposerService()
    let model = WhatsAppWorkspaceModel(worker: service, polling: false)
    await model.load(configuration: .init(connectionString: "synthetic service boundary"))
    await model.selectChat("peer@lid")
    let first = service.first.id
    let second = service.second.id
    model.composerText = "First draft"
    let firstSend = Task { await model.sendCompose() }
    for _ in 0..<100 {
      if await service.waiting(first) { break }
      await Task.yield()
    }
    let firstWaiting = await service.waiting(first)
    XCTAssertTrue(firstWaiting)
    await model.selectAccount(second)
    await model.selectChat("peer@lid")
    model.composerText = "Second draft"
    let secondSend = Task { await model.sendCompose() }
    for _ in 0..<100 {
      if await service.waiting(second) { break }
      await Task.yield()
    }
    let secondWaiting = await service.waiting(second)
    XCTAssertTrue(secondWaiting)
    await service.complete(first)
    await firstSend.value
    XCTAssertEqual(model.composerText, "Second draft")
    XCTAssertTrue(model.sending)
    model.composerText = "A new second draft"
    await service.complete(second)
    await secondSend.value
    XCTAssertEqual(model.composerText, "A new second draft")
    XCTAssertFalse(model.sending)
  }
}

private actor InspectService: WhatsAppServing {
  let first = WhatsAppAccount(name: "First"), second = WhatsAppAccount(name: "Second")
  private var response: CheckedContinuation<WhatsAppPeerInfo, any Error>?
  func waiting() -> Bool { response != nil }
  func complete() {
    var info = WhatsAppPeerInfo()
    info.name = "First private profile"
    response?.resume(returning: info)
    response = nil
  }
  func info(accountID: UUID, chat: String, operation: WhatsAppAction.Operation) async throws
    -> WhatsAppPeerInfo
  { try await withCheckedThrowingContinuation { response = $0 } }
  func load(configuration: ContactWorkspaceConfiguration) -> [WhatsAppAccount] { [first, second] }
  func addAccount(name: String) -> WhatsAppAccount { .init(name: name) }
  func snapshot(accountID: UUID) -> WhatsAppWorkspaceSnapshot {
    .init(accountID: accountID, status: .init(), chats: [])
  }
  func messages(accountID: UUID, chat: String, before: WhatsAppCursor?) -> [WhatsAppMessage] { [] }
  func connect(accountID: UUID) {}
  func disconnect(accountID: UUID) {}
  func shutdown() {}
}
@MainActor final class WhatsAppActionsModelTests: XCTestCase {
  func testLateProfileCannotEnterAnotherAccountContext() async throws {
    let worker = InspectService()
    let model = WhatsAppActionsModel(worker: worker)
    model.setContext(account: worker.first.id, chat: "peer@lid")
    let loading = Task { await model.inspect(.userInfo) }
    for _ in 0..<100 {
      if await worker.waiting() { break }
      await Task.yield()
    }
    model.setContext(account: worker.second.id, chat: "peer@lid")
    await worker.complete()
    await loading.value
    XCTAssertNil(model.info)
    XCTAssertFalse(model.busy)
    XCTAssertNil(model.error)
  }
}

private actor ActionScopeBoundary: WhatsAppServing {
  private(set) var count = 0
  func perform(accountID: UUID, chat: String, action: WhatsAppAction) -> WhatsAppOutgoing {
    count += 1
    return .init(
      id: UUID(), accountID: accountID, chat: chat,
      content: .init(text: action.text, action: action), created: Date(), state: .sent)
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
extension WhatsAppActionsModelTests {
  func testOldContextMenuCannotSendToSameChatInAnotherAccount() async throws {
    let worker = ActionScopeBoundary()
    let model = WhatsAppActionsModel(worker: worker)
    let first = UUID()
    let second = UUID()
    model.setContext(account: first, chat: "peer@lid")
    model.setContext(account: second, chat: "peer@lid")
    let value = await model.perform(
      .init(.react, text: "👍", target: "message"), expectedAccount: first, expectedChat: "peer@lid")
    let count = await worker.count
    XCTAssertNil(value)
    XCTAssertEqual(count, 0)
  }
}
