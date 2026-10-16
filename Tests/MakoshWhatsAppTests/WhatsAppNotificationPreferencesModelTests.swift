import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

private actor PreferencesBoundary: WhatsAppServing {
  let first = UUID(), second = UUID()
  var pending: CheckedContinuation<WhatsAppNotificationRule, any Error>?
  private(set) var writes: [UUID?] = []
  func waiting() -> Bool { pending != nil }
  func finish() {
    var rule = WhatsAppNotificationRule()
    rule.show = false
    pending?.resume(returning: rule)
    pending = nil
  }
  func savedNotificationRule(accountID: UUID?, chat: String?) async throws
    -> WhatsAppNotificationRule
  {
    if accountID == first { return try await withCheckedThrowingContinuation { pending = $0 } }
    return .init()
  }
  func savingFiles(accountID: UUID, chat: String) -> Bool { true }
  func setSavingFiles(accountID: UUID, chat: String, enabled: Bool) { writes.append(accountID) }
  func setNotificationRule(_ rule: WhatsAppNotificationRule, accountID: UUID?, chat: String?) {
    writes.append(accountID)
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
@MainActor final class WhatsAppNotificationPreferencesModelTests: XCTestCase {
  func testOldLoadOrSaveCannotWriteRulesIntoNewAccount() async throws {
    let worker = PreferencesBoundary()
    let model = WhatsAppNotificationPreferencesModel(worker: worker)
    model.reset(worker.first)
    let old = Task { await model.load(expectedAccount: worker.first) }
    for _ in 0..<100 {
      if await worker.waiting() { break }
      await Task.yield()
    }
    model.reset(worker.second)
    await model.save(expectedAccount: worker.second)
    await worker.finish()
    await old.value
    XCTAssertFalse(model.loaded)
    XCTAssertTrue(model.rule.show)
    await model.load(expectedAccount: worker.second)
    await model.save(expectedAccount: worker.first)
    let empty = await worker.writes
    XCTAssertTrue(empty.isEmpty)
    await model.save(expectedAccount: worker.second)
    let saved = await worker.writes
    XCTAssertEqual(saved, [worker.second])
  }
}

@MainActor final class WhatsAppChatSettingsAdmissionTests: XCTestCase {
  func testChatSaveWaitsForBothSettingsAndRejectsOldContext() async throws {
    let worker = PreferencesBoundary()
    let model = WhatsAppActionsModel(worker: worker)
    model.setContext(account: worker.first, chat: "first@lid")
    let pending = Task { await model.loadSettings() }
    for _ in 0..<200 { if await worker.waiting() { break }; await Task.yield() }
    await model.saveSettings()
    let premature = await worker.writes
    XCTAssertTrue(premature.isEmpty, "defaults cannot be saved while persisted policy is suspended")
    model.setContext(account: worker.second, chat: "second@lid")
    await worker.finish()
    await pending.value
    await model.saveSettings()
    let stale = await worker.writes
    XCTAssertTrue(stale.isEmpty, "old load must not authorize saving a different chat")
    await model.loadSettings()
    XCTAssertTrue(model.saving)
    await model.saveSettings()
    let saved = await worker.writes
    XCTAssertEqual(saved, [worker.second, worker.second])
  }
}
