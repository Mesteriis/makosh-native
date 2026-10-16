import XCTest
import UserNotifications
@testable import MakoshApp
@testable import MakoshTeams

@MainActor final class TeamsNotificationCenterFixture: ApplicationSystemNotificationCenter {
    var permission: UNAuthorizationStatus = .notDetermined
    var consent: (@Sendable (Bool, (any Error)?) -> Void)?
    var consentCount = 0
    var holdAdd = false
    var added: (@Sendable ((any Error)?) -> Void)?
    var requests: [UNNotificationRequest] = []
    var removed: [String] = []
    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) { completionHandler(permission) }
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void) { consentCount += 1; consent = completionHandler }
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?) {
        requests.append(request)
        if holdAdd { added = completionHandler } else { completionHandler?(nil) }
    }
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void) { completionHandler([]) }
    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void) { completionHandler(requests) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { removed += identifiers; requests.removeAll { identifiers.contains($0.identifier) } }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { removed += identifiers }
}
actor TeamsNotificationPolicyFixture: TeamsNotificationServing {
    var eligible = true
    var rule = TeamsNotificationRule()
    var paused = false
    var saved: CheckedContinuation<TeamsNotificationRule, Never>?
    var observed: CheckedContinuation<Void, Never>?
    func pauseSaved() { paused = true }
    func waitForSaved() async { if saved != nil { return }; await withCheckedContinuation { observed = $0 } }
    func finishSaved() { saved?.resume(returning: rule); saved = nil; paused = false }
    func mutate(_ kind: Int) { if kind == 0 { rule.preview = false }; if kind == 1 { rule.sound = false }; if kind == 2 { eligible = false }; if kind == 3 { rule.foreground = false } }
    func savedNotificationRule(scope: TeamsNotificationScope) async -> TeamsNotificationRule {
        if !paused { return rule }
        return await withCheckedContinuation { saved = $0; observed?.resume(); observed = nil }
    }
    func setNotificationRule(_ rule: TeamsNotificationRule, scope: TeamsNotificationScope) { self.rule = rule }
    func notificationRule(conversation: TeamsScope) -> TeamsNotificationRule { rule }
    func notificationIsCurrent(_ event: TeamsNotificationEvent) -> Bool { eligible }
    func claimNotifications(accountID: UUID) -> [TeamsNotificationEvent] { [] }
    func activateNotification(token: String) -> TeamsNotificationEvent? { nil }
    func markLocallyRead(scope: TeamsScope) { eligible = false }
}
@MainActor final class TeamsWindowFixture {
    var state = ApplicationNotificationWindowState(applicationActive: true, hasWindow: true, key: false, visible: true, miniaturized: false)
}
@MainActor final class TeamsSystemNotificationTests: XCTestCase {
    var event: TeamsNotificationEvent { .init(id: String(repeating: "a", count: 43), thread: String(repeating: "b", count: 43), scope: teamsTestScope, messageID: "incoming", sequence: 1, title: "Private", body: "Secret", timestamp: Int64(Date().timeIntervalSince1970)) }
    func testLatePreferenceLoadCannotFollowAnotherAccount() async throws {
        let policy = TeamsNotificationPolicyFixture()
        await policy.pauseSaved(); await policy.mutate(0)
        let model = TeamsNotificationPreferencesModel(worker: policy)
        model.reset(.global)
        let loading = Task { await model.load(expectedScope: .global) }
        await policy.waitForSaved()
        model.reset(.account(UUID()))
        await policy.finishSaved(); await loading.value
        XCTAssertFalse(model.loaded); XCTAssertFalse(model.canSave); XCTAssertTrue(model.rule.preview)
    }
    func testDeniedConsentDoesNotPromptOnEveryMessage() async throws {
        let policy = TeamsNotificationPolicyFixture(), center = TeamsNotificationCenterFixture()
        let system = TeamsSystemNotifications(worker: policy, center: center)
        let router = ApplicationSystemNotificationRouter(registerSystemDelegate: false); system.attach(router)
        let first = Task { await system.deliver(self.event) }
        for _ in 0..<200 { if center.consent != nil { break }; await Task.yield() }
        XCTAssertNotNil(center.consent)
        center.consent?(false, NSError(domain: "synthetic", code: 1)); await first.value
        await system.deliver(event)
        XCTAssertEqual(center.consentCount, 1); XCTAssertTrue(center.requests.isEmpty)
    }
    func testCallbackRechecksPreviewSoundAccountAndWindowAfterConsent() async throws {
        for mutation in 0..<4 {
            let policy = TeamsNotificationPolicyFixture(), center = TeamsNotificationCenterFixture(), window = TeamsWindowFixture()
            let router = ApplicationSystemNotificationRouter(registerSystemDelegate: false)
            let system = TeamsSystemNotifications(worker: policy, center: center, windowState: { window.state })
            system.attach(router)
            let delivery = Task { await system.deliver(self.event) }
            for _ in 0..<200 { if center.consent != nil { break }; await Task.yield() }
            XCTAssertNotNil(center.consent)
            await policy.mutate(mutation)
            if mutation == 3 { window.state.key = true }
            center.permission = .authorized; center.consent?(true, nil)
            await delivery.value
            if mutation < 2 {
                XCTAssertEqual(center.requests.count, 1)
                if mutation == 0 { XCTAssertEqual(center.requests.first?.content.body, "Новое сообщение") }
                if mutation == 1 { XCTAssertNil(center.requests.first?.content.sound) }
                await policy.mutate(2)
                let allowed = await system.canPresent(event.id); XCTAssertFalse(allowed)
            } else { XCTAssertTrue(center.requests.isEmpty) }
            XCTAssertEqual(center.consentCount, 1)
        }
    }
    func testLateAddCompletionWithdrawsOldPrivateContent() async throws {
        let policy = TeamsNotificationPolicyFixture(), center = TeamsNotificationCenterFixture()
        center.permission = .authorized; center.holdAdd = true
        let system = TeamsSystemNotifications(worker: policy, center: center)
        let delivery = Task { await system.deliver(self.event) }
        for _ in 0..<200 { if center.added != nil { break }; await Task.yield() }
        XCTAssertNotNil(center.added)
        await policy.mutate(0); center.added?(nil); await delivery.value
        XCTAssertTrue(center.removed.contains("makosh.teams." + event.id))
        XCTAssertTrue(center.requests.isEmpty)
    }
    func testOneApplicationDelegatePreservesAllServiceRoutes() async throws {
        let router = ApplicationSystemNotificationRouter(registerSystemDelegate: false)
        let policy = TeamsNotificationPolicyFixture(), center = TeamsNotificationCenterFixture()
        center.permission = .authorized
        let system = TeamsSystemNotifications(worker: policy, center: center); system.attach(router)
        await system.deliver(event)
        XCTAssertTrue(router.systemIdentifiers.contains("makosh.teams." + event.id))
        let current = await router.teamsRegistry.canPresent(event.id); XCTAssertTrue(current)
        XCTAssertFalse(router.registry.identifiers.contains(event.id))
        XCTAssertFalse(router.mailRegistry.identifiers.contains(event.id))
        XCTAssertFalse(router.whatsappRegistry.identifiers.contains(event.id))
    }
}
