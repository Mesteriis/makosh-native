import MakoshCore
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

@MainActor final class WhatsAppAvatarModelTests: XCTestCase {
  func testOldAccountResultCannotPublishInNewScope() async throws {
    let first = UUID()
    let second = UUID()
    let fixture = AvatarModelService(
      image: .init(encodedPreview: try avatarJPEG(), width: 48, height: 24, pictureID: "old"))
    let model = WhatsAppAvatarModel(worker: fixture, cache: .init())
    let old = Task { await model.load(scope: .init(accountID: first, jid: "same@lid")) }
    for _ in 0..<100 where !(await fixture.waiting()) {
      try await Task.sleep(for: .milliseconds(2))
    }
    let waiting = await fixture.waiting()
    XCTAssertTrue(waiting)
    let scope = WhatsAppAvatarScope(accountID: second, jid: "same@lid")
    await model.load(scope: scope)
    await fixture.release()
    await old.value
    XCTAssertEqual(model.scope, scope)
    XCTAssertNil(model.image)
  }
  func testDecodedWindowCacheHasExactCostLimitAndAccountIdentity() async throws {
    let cache = WhatsAppAvatarWindowCache(maximumCost: 5000)
    let image = WhatsAppAvatarImage(
      encodedPreview: try avatarJPEG(), width: 48, height: 24, pictureID: "same")
    let a = WhatsAppAvatarScope(accountID: UUID(), jid: "same@lid")
    let b = WhatsAppAvatarScope(accountID: UUID(), jid: "same@lid")
    let first = try await cache.image(image, scope: a)
    let second = try await cache.image(image, scope: b)
    XCTAssertFalse(first === second)
    XCTAssertEqual(cache.count, 1)
    XCTAssertLessThanOrEqual(cache.cost, 5000)
    cache.invalidate(b)
    XCTAssertEqual(cache.count, 0)
  }
}
private actor AvatarModelService: WhatsAppServing {
  let image: WhatsAppAvatarImage
  var calls = 0
  var continuation: CheckedContinuation<Void, Never>?
  init(image: WhatsAppAvatarImage) { self.image = image }
  func waiting() -> Bool { continuation != nil }
  func release() {
    continuation?.resume()
    continuation = nil
  }
  func avatar(accountID: UUID, jid: String, refresh: Bool) async throws -> WhatsAppAvatarImage? {
    calls += 1
    if calls == 1 {
      await withCheckedContinuation { continuation = $0 }
      return image
    }
    return nil
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
