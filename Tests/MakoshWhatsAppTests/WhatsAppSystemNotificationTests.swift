import MakoshCore
import UserNotifications
import XCTest

@testable import MakoshApp
@testable import MakoshWhatsApp

@MainActor
private final class WhatsAppNotificationCenterFixture: ApplicationSystemNotificationCenter {
  var permission: UNAuthorizationStatus = .notDetermined
  var consent: (@Sendable (Bool, (any Error)?) -> Void)?
  var requests: [UNNotificationRequest] = []
  func getAuthorizationStatus(
    completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void
  ) { completionHandler(permission) }
  func requestAuthorization(
    options: UNAuthorizationOptions,
    completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
  ) { consent = completionHandler }
  func add(
    _ request: UNNotificationRequest,
    withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?
  ) {
    requests.append(request)
    completionHandler?(nil)
  }
  func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void)
  { completionHandler([]) }
  func getPendingNotificationRequests(
    completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void
  ) { completionHandler(requests) }
  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    requests.removeAll { identifiers.contains($0.identifier) }
  }
  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
}
private actor NotificationPolicyFixture: WhatsAppServing {
  var eligible = true
  var rule = WhatsAppNotificationRule()
  func hidePreview() { rule.preview = false }
  func revoke() { eligible = false }
  func notificationIsCurrent(_ event: WhatsAppNotificationEvent) -> Bool { eligible }
  func notificationRule(accountID: UUID, chat: String) -> WhatsAppNotificationRule { rule }
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
@MainActor final class WhatsAppSystemNotificationTests: XCTestCase {
  func testCallbackVetoesChangedPreviewWithoutPeriodicRevalidation() async throws {
    let worker = NotificationPolicyFixture()
    let center = WhatsAppNotificationCenterFixture()
    center.permission = .authorized
    let system = WhatsAppSystemNotifications(worker: worker, center: center)
    let event = WhatsAppNotificationEvent(id: String(repeating: "e", count: 64), thread: "thread", accountID: UUID(), chat: "peer@lid", messageID: "m", title: "Private", body: "Secret", timestamp: Int64(Date().timeIntervalSince1970))
    await system.deliver(event)
    XCTAssertEqual(center.requests.count, 1)
    await worker.hidePreview()
    let allowed = await system.canPresent(event.id)
    XCTAssertFalse(allowed)
    XCTAssertTrue(center.requests.isEmpty)
  }
  func testTurningPreviewOffWithdrawsAnAlreadySubmittedPrivateBanner() async throws {
    let worker = NotificationPolicyFixture()
    let center = WhatsAppNotificationCenterFixture()
    let router = ApplicationSystemNotificationRouter(registerSystemDelegate: false)
    center.permission = .authorized
    let system = WhatsAppSystemNotifications(worker: worker, center: center)
    system.attach(router)
    let event = WhatsAppNotificationEvent(
      id: String(repeating: "c", count: 64), thread: String(repeating: "d", count: 64),
      accountID: UUID(), chat: "peer@lid", messageID: "m", title: "Private", body: "Secret",
      timestamp: Int64(Date().timeIntervalSince1970))
    await system.deliver(event)
    XCTAssertEqual(center.requests.count, 1)
    await worker.hidePreview()
    await system.revalidate()
    XCTAssertTrue(center.requests.isEmpty)
  }
  func testRevokedAccountDuringConsentCannotPublishPrivateNotification() async throws {
    let worker = NotificationPolicyFixture()
    let center = WhatsAppNotificationCenterFixture()
    let router = ApplicationSystemNotificationRouter(registerSystemDelegate: false)
    let system = WhatsAppSystemNotifications(worker: worker, center: center)
    system.attach(router)
    let event = WhatsAppNotificationEvent(
      id: String(repeating: "a", count: 64), thread: String(repeating: "b", count: 64),
      accountID: UUID(), chat: "peer@lid", messageID: "m", title: "Private", body: "Secret",
      timestamp: Int64(Date().timeIntervalSince1970))
    let delivery = Task { await system.deliver(event) }
    for _ in 0..<200 {
      if center.consent != nil { break }
      await Task.yield()
    }
    XCTAssertNotNil(center.consent)
    await worker.revoke()
    center.permission = .authorized
    center.consent?(true, nil)
    await delivery.value
    XCTAssertTrue(center.requests.isEmpty)
  }
}
