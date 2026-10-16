import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

private actor PickerBoundary: WhatsAppServing {
  var pending: [String: CheckedContinuation<WhatsAppPeerInfo, any Error>] = [:]
  func info(accountID: UUID, chat: String, operation: WhatsAppAction.Operation) async throws
    -> WhatsAppPeerInfo
  { try await withCheckedThrowingContinuation { pending[chat] = $0 } }
  func waiting(_ chat: String) -> Bool { pending[chat] != nil }
  func finish(_ chat: String, _ info: WhatsAppPeerInfo) {
    pending.removeValue(forKey: chat)?.resume(returning: info)
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
@MainActor final class WhatsAppGroupCallPickerTests: XCTestCase {
  private func info(_ jid: String) -> WhatsAppPeerInfo {
    var i = WhatsAppPeerInfo()
    i.jid = jid
    i.members = [
      .init(jid: "me@lid", admin: false, me: true), .init(jid: "a@lid", admin: false, me: false),
      .init(jid: "a@lid", admin: true, me: false), .init(jid: "b@lid", admin: false, me: false),
    ]
    return i
  }
  func testParticipantSelectionExcludesSelfAndDeduplicates() async throws {
    let worker = PickerBoundary()
    let m = WhatsAppGroupCallPickerModel(worker: worker)
    let id = UUID()
    let task = Task { await m.load(accountID: id, groupJID: "1@g.us") }
    for _ in 0..<100 {
      if await worker.waiting("1@g.us") { break }
      await Task.yield()
    }
    await worker.finish("1@g.us", info("1@g.us"))
    await task.value
    XCTAssertEqual(m.members.map(\.jid), ["a@lid", "b@lid"])
    XCTAssertTrue(m.selected.isEmpty)
    m.toggle("me@lid")
    m.toggle("a@lid")
    XCTAssertThrowsError(try m.targets())
    m.toggle("b@lid")
    XCTAssertEqual(try m.targets(), ["a@lid", "b@lid"])
    m.toggle("a@lid")
    XCTAssertThrowsError(try m.targets())
  }
  func testDelayedRosterOrPermissionRejectsNewContext() async throws {
    let worker = PickerBoundary()
    let m = WhatsAppGroupCallPickerModel(worker: worker)
    let a = Task { await m.load(accountID: UUID(), groupJID: "1@g.us") }
    for _ in 0..<100 {
      if await worker.waiting("1@g.us") { break }
      await Task.yield()
    }
    let b = Task { await m.load(accountID: UUID(), groupJID: "2@g.us") }
    for _ in 0..<100 {
      if await worker.waiting("2@g.us") { break }
      await Task.yield()
    }
    await worker.finish("2@g.us", info("2@g.us"))
    await b.value
    m.toggle("a@lid")
    await worker.finish("1@g.us", info("1@g.us"))
    await a.value
    XCTAssertEqual(m.groupJID, "2@g.us")
    XCTAssertEqual(m.selected, ["a@lid"])
  }
  func testNineVisibleStreamsPagingAndPinnedTile() throws {
    let people = (0..<32).map { n in
      WhatsAppCallParticipant(
        jid: "p\(n)@lid", state: "connected", devices: [.init(jid: "p\(n):2@lid", pid: UInt32(n))],
        me: n == 0)
    }
    var layout = WhatsAppGroupCallLayout(participants: people)
    XCTAssertEqual(layout.visibleParticipants.count, 9)
    XCTAssertFalse(layout.visibleParticipants.contains { $0.me == true })
    layout.pinned = "p1@lid"
    layout.page = 2
    XCTAssertEqual(layout.visibleParticipants.first?.jid, "p1@lid")
    XCTAssertEqual(layout.visibleStreams.count, 9)
    XCTAssertEqual(Set(layout.visibleStreams).count, 9)
    layout.page = 999
    XCTAssertLessThanOrEqual(layout.visibleStreams.count, 9)
  }
}
