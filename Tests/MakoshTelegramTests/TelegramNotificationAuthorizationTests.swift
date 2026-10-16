import XCTest
import Combine
import UserNotifications
@testable import MakoshApp
@testable import MakoshTelegram

@MainActor private final class NotificationCenterFixture: TelegramSystemNotificationCenter {
    var authorization: UNAuthorizationStatus = .notDetermined
    var requested: [UNAuthorizationOptions] = []
    var added: [UNNotificationRequest] = []
    var authorizationCompletion: (@Sendable (Bool, (any Error)?) -> Void)?
    var didRequest: (() -> Void)?
    var didAdd: (() -> Void)?
    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        completionHandler(authorization)
    }
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        requested.append(options); authorizationCompletion = completionHandler; didRequest?()
    }
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?) {
        added.append(request); completionHandler?(nil); didAdd?()
    }
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) { completionHandler([]) }
    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) { completionHandler([]) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func completeAuthorization(granted: Bool) {
        authorization = granted ? .authorized : .denied
        let completion = authorizationCompletion; authorizationCompletion = nil; completion?(granted, nil)
    }
    func failAuthorization() {
        let completion = authorizationCompletion; authorizationCompletion = nil
        completion?(false, NSError(domain: "org.makosh.synthetic-notification", code: 1))
    }
}

@MainActor final class TelegramNotificationAuthorizationTests: XCTestCase {
    private func controller() -> TelegramNotificationController {
        let suite = "org.makosh.notification-authorization.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let controller = TelegramNotificationController(defaults: defaults)
        controller.bind(accountID: 1)
        var p = controller.preferences; p.suppressWhileActive = false
        XCTAssertTrue(controller.update(p, contextID: controller.contextID))
        return controller
    }
    private func incoming(_ controller: TelegramNotificationController, id: Int32 = 1, account: Int64 = 1) {
        controller.receive(.init(accountID: account, peerID: 42, namespace: 0, messageID: id, threadID: nil,
            timestamp: Int32(Date().timeIntervalSince1970), category: .personal, title: "Synthetic chat",
            text: try? .init(text: "Synthetic incoming"), fallback: "Новое сообщение", incoming: true,
            serverNotify: true, serverPreviews: true, serverSilent: false, secret: false,
            protected: false, serviceCodes: false), contextID: controller.contextID)
    }
    func testFirstEligibleIncomingRequestsPermissionAndSubmitsAfterGrant() async {
        let controller = controller(), center = NotificationCenterFixture()
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center)
        system.attach(router)
        let requested = expectation(description: "First eligible incoming requests macOS consent")
        center.didRequest = { requested.fulfill() }
        incoming(controller)
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(center.requested, [[.alert, .sound, .badge]])
        XCTAssertTrue(center.added.isEmpty)
        let submitted = expectation(description: "Granted incoming reaches macOS")
        center.didAdd = { submitted.fulfill() }
        center.completeAuthorization(granted: true)
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added.first?.content.body, "Synthetic incoming")
    }
    func testDeniedIncomingDoesNotSubmitOrAskAgain() async {
        let controller = controller(), center = NotificationCenterFixture()
        center.authorization = .denied
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center)
        let observed = expectation(description: "Read denied authorization")
        let subscription = system.$authorization.sink { if $0 == .denied { observed.fulfill() } }
        defer { subscription.cancel() }
        await fulfillment(of: [observed], timeout: 2)
        subscription.cancel()
        system.attach(router); incoming(controller)
        await Task.yield()
        XCTAssertTrue(center.requested.isEmpty)
        XCTAssertTrue(center.added.isEmpty)
    }
    func testAccountReplacementWhileConsentPendingCannotSubmitOldPrivateContent() async {
        let controller = controller(), center = NotificationCenterFixture()
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center)
        system.attach(router)
        let requested = expectation(description: "Consent starts")
        center.didRequest = { requested.fulfill() }
        incoming(controller)
        await fulfillment(of: [requested], timeout: 2)
        controller.bind(accountID: 2)
        let completed = expectation(description: "Consent completes after account change")
        let subscription = system.$requesting.dropFirst().sink { if !$0 { completed.fulfill() } }
        defer { subscription.cancel() }
        center.completeAuthorization(granted: true)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(center.added.isEmpty)
    }
    func testAuthorizedIncomingSubmitsOnceWithoutPromptAndKeepsOpaquePayload() async {
        let controller = controller(), center = NotificationCenterFixture()
        center.authorization = .authorized
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center)
        system.attach(router)
        let submitted = expectation(description: "Authorized incoming is submitted")
        center.didAdd = { submitted.fulfill() }
        incoming(controller); incoming(controller)
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(center.added.count, 1); XCTAssertTrue(center.requested.isEmpty)
        XCTAssertEqual(center.added.first?.content.userInfo.count, 1)
        XCTAssertNotNil(center.added.first?.content.userInfo["makosh.telegram.token"] as? String)
    }
    func testPermissionDeniedDuringPromptDropsPendingAndNeverReprompts() async {
        let controller = controller(), center = NotificationCenterFixture()
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center)
        system.attach(router)
        let requested = expectation(description: "Consent requested")
        center.didRequest = { requested.fulfill() }
        incoming(controller)
        await fulfillment(of: [requested], timeout: 2)
        let denied = expectation(description: "Denied state read")
        let subscription = system.$authorization.sink { if $0 == .denied { denied.fulfill() } }
        defer { subscription.cancel() }
        center.completeAuthorization(granted: false)
        await fulfillment(of: [denied], timeout: 2)
        subscription.cancel()
        let unexpected = expectation(description: "Denied incoming must never be submitted"); unexpected.isInverted = true
        center.didAdd = { unexpected.fulfill() }; center.didRequest = { XCTFail("Must not reprompt after denial") }
        incoming(controller, id: 2)
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertTrue(center.added.isEmpty); XCTAssertEqual(center.requested.count, 1)
    }
    func testPrivacyForegroundAndLockChangesWhileConsentPendingSuppressStaleCards() async {
        for change in 0..<3 {
            let controller = controller(), center = NotificationCenterFixture()
            var preferences = controller.preferences; preferences.suppressWhileActive = true
            XCTAssertTrue(controller.update(preferences, contextID: controller.contextID))
            var windowActive = false
            let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
            let system = TelegramSystemNotifications(controller: controller, center: center, windowState: {
                .init(applicationActive: windowActive, hasWindow: true, key: true, visible: true, miniaturized: false)
            })
            system.attach(router)
            let requested = expectation(description: "Consent before presentation change \(change)")
            center.didRequest = { requested.fulfill() }
            incoming(controller)
            await fulfillment(of: [requested], timeout: 2)
            switch change {
            case 0:
                preferences.previews = false
                XCTAssertTrue(controller.update(preferences, contextID: controller.contextID))
            case 1: windowActive = true
            default: controller.setPresentationEnvironment(active: false, locked: true)
            }
            let unexpected = expectation(description: "Stale private card must not be submitted \(change)"); unexpected.isInverted = true
            center.didAdd = { unexpected.fulfill() }
            center.completeAuthorization(granted: true)
            await fulfillment(of: [unexpected], timeout: 0.1)
            XCTAssertTrue(center.added.isEmpty)
        }
    }
    func testConsentQueueIsBoundedAndDuplicateIncomingDoesNotCreateMorePrompts() async {
        let controller = controller(), center = NotificationCenterFixture()
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center)
        system.attach(router)
        let requested = expectation(description: "One permission prompt")
        center.didRequest = { requested.fulfill() }
        incoming(controller)
        await fulfillment(of: [requested], timeout: 2)
        for id: Int32 in 1...105 { incoming(controller, id: id) }
        XCTAssertEqual(center.requested.count, 1); XCTAssertTrue(center.added.isEmpty)
        let submitted = expectation(description: "Only newest bounded pending cards are submitted")
        submitted.expectedFulfillmentCount = 100
        center.didAdd = { submitted.fulfill() }
        center.completeAuthorization(granted: true)
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(center.added.count, 100); XCTAssertEqual(Set(center.added.map(\.identifier)).count, 100)
        XCTAssertEqual(center.requested.count, 1)
    }
    func testAutomaticAuthorizationErrorDoesNotRetryOnEachIncomingButManualRetryWorks() async {
        let controller = controller(), center = NotificationCenterFixture()
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center)
        system.attach(router)
        let requested = expectation(description: "Initial automatic consent")
        center.didRequest = { requested.fulfill() }
        incoming(controller)
        await fulfillment(of: [requested], timeout: 2)
        let completed = expectation(description: "Authorization error handled")
        let subscription = system.$requesting.dropFirst().sink { if !$0 { completed.fulfill() } }
        center.failAuthorization()
        await fulfillment(of: [completed], timeout: 2)
        subscription.cancel()
        let unexpected = expectation(description: "Later incoming must not repeat automatic prompt"); unexpected.isInverted = true
        center.didRequest = { unexpected.fulfill() }
        incoming(controller, id: 2)
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertEqual(center.requested.count, 1); XCTAssertTrue(center.added.isEmpty)
        let manual = expectation(description: "Explicit user action may retry consent")
        center.didRequest = { manual.fulfill() }
        system.requestAuthorization()
        await fulfillment(of: [manual], timeout: 2)
        XCTAssertEqual(center.requested.count, 2)
    }
    func testManualFirstAuthorizationErrorRequiresAnotherExplicitActionToRetry() async {
        let controller = controller(), center = NotificationCenterFixture()
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center)
        system.attach(router)
        let requested = expectation(description: "First consent requested by settings action")
        center.didRequest = { requested.fulfill() }
        system.requestAuthorization()
        await fulfillment(of: [requested], timeout: 2)
        let completed = expectation(description: "Manual consent error handled")
        let subscription = system.$requesting.dropFirst().sink { if !$0 { completed.fulfill() } }
        center.failAuthorization()
        await fulfillment(of: [completed], timeout: 2)
        subscription.cancel()
        let unexpected = expectation(description: "Incoming cannot retry failed manual consent"); unexpected.isInverted = true
        center.didRequest = { unexpected.fulfill() }
        incoming(controller)
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertEqual(center.requested.count, 1); XCTAssertTrue(center.added.isEmpty)
        let manual = expectation(description: "A second explicit action may retry")
        center.didRequest = { manual.fulfill() }
        system.requestAuthorization()
        await fulfillment(of: [manual], timeout: 2)
        XCTAssertEqual(center.requested.count, 2)
    }
    func testGrantStartedForOldAccountOnlySubmitsCurrentAccountQueuedCard() async {
        let controller = controller(), center = NotificationCenterFixture()
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center)
        system.attach(router)
        let requested = expectation(description: "Old account consent starts")
        center.didRequest = { requested.fulfill() }
        incoming(controller)
        await fulfillment(of: [requested], timeout: 2)
        controller.bind(accountID: 2)
        var preferences = controller.preferences; preferences.suppressWhileActive = false
        XCTAssertTrue(controller.update(preferences, contextID: controller.contextID))
        incoming(controller, id: 2, account: 2)
        let currentID = controller.delivery?.id
        let submitted = expectation(description: "Current account validated after consent")
        center.didAdd = { submitted.fulfill() }
        center.completeAuthorization(granted: true)
        await fulfillment(of: [submitted], timeout: 2)
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added.first?.content.userInfo["makosh.telegram.token"] as? String, currentID)
        XCTAssertEqual(center.requested.count, 1)
    }
    func testConsentRechecksCurrentWindowFlagsWithoutWaitingForWindowNotification() async {
        let controller = controller(), center = NotificationCenterFixture()
        var preferences = controller.preferences; preferences.suppressWhileActive = true
        XCTAssertTrue(controller.update(preferences, contextID: controller.contextID))
        var state = TelegramNotificationWindowState(applicationActive: true, hasWindow: true,
            key: false, visible: true, miniaturized: true)
        let router = TelegramSystemNotificationRouter(registerSystemDelegate: false)
        let system = TelegramSystemNotifications(controller: controller, center: center, windowState: { state })
        system.attach(router)
        let requested = expectation(description: "Minimized window allows initial consent")
        center.didRequest = { requested.fulfill() }
        incoming(controller)
        await fulfillment(of: [requested], timeout: 2)
        state.key = true; state.miniaturized = false
        let unexpected = expectation(description: "Restored foreground window suppresses pending card"); unexpected.isInverted = true
        center.didAdd = { unexpected.fulfill() }
        center.completeAuthorization(granted: true)
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertTrue(center.added.isEmpty)
    }
}
