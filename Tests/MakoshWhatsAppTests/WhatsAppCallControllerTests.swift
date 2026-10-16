import AppKit
import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

private actor HeldCallMedia: WhatsAppCallMediaServing {
  private var waiting: CheckedContinuation<Void, any Error>?
  private(set) var stops = 0
  func ready() -> Bool { waiting != nil }
  func finish() {
    waiting?.resume()
    waiting = nil
  }
  func start(selection: WhatsAppCallDeviceSelection, video: Bool) async throws {
    try await withCheckedThrowingContinuation { waiting = $0 }
  }
  func setVideo(_ on: Bool) {}
  func setMuted(_ on: Bool) {}
  func input() -> WhatsAppCallMediaInput { .init(audio: [], video: []) }
  func receive(_ output: WhatsAppCallOutput) {}
  func images() -> WhatsAppCallImages { .init(local: nil, remote: nil) }
  func stop() { stops += 1 }
}
private actor CallBoundary: WhatsAppServing {
  private(set) var operations: [WhatsAppAction.Operation] = []
  func perform(accountID: UUID, chat: String, action: WhatsAppAction) async throws
    -> WhatsAppOutgoing
  {
    operations.append(action.op)
    return .init(
      id: UUID(), accountID: accountID, chat: chat, content: .init(text: "", action: action),
      created: Date(), state: .sent)
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
@MainActor final class WhatsAppCallControllerTests: XCTestCase {
  func testEndDuringDeviceStartupRevokesProtocolAdmission() async throws {
    let worker = CallBoundary()
    let media = HeldCallMedia()
    let model = WhatsAppCallController(
      worker: worker, synthetic: false, permission: { _ in true }, makeMedia: { media })
    model.start(accountID: UUID(), peer: "test@lid", video: false)
    for _ in 0..<200 {
      if await media.ready() { break }
      await Task.yield()
    }
    let ready = await media.ready()
    XCTAssertTrue(ready)
    await model.end()
    await media.finish()
    for _ in 0..<200 { await Task.yield() }
    let operations = await worker.operations
    XCTAssertFalse(operations.contains(.callStart))
    XCTAssertNil(model.call)
  }
}

extension WhatsAppCallControllerTests {
  func testInitialVideoPanelHasHostedContentAndCloseEndsPreview() async throws {
    _ = NSApplication.shared
    let model = WhatsAppCallController(worker: CallBoundary(), synthetic: true)
    let owner = WhatsAppCallPanel(controller: model)
    model.preview()
    for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
    let panel = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "Звонок WhatsApp" && $0.isVisible })
    panel.contentView?.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(panel.contentView?.frame.height ?? 0, 600, "initial video host must retain its usable content area")
    panel.performClose(nil)
    for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNil(model.call)
    XCTAssertFalse(panel.isVisible)
    withExtendedLifetime(owner) {}
  }
}
