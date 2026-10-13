import XCTest
import UserNotifications
@testable import MakoshApp
@testable import MakoshTelegram

@MainActor final class TelegramSystemNotificationTests: XCTestCase {
    func testSystemPayloadContainsOnlyOpaqueActivationTokenAndNoReplyOrMediaSideEffects() {
        let content = telegramSystemNotificationContent(.init(id: "opaque-uuid", title: "Alice", body: "Hello ██████", sound: true, bounce: false))
        XCTAssertEqual(content.title, "Alice"); XCTAssertEqual(content.body, "Hello ██████")
        XCTAssertEqual(content.userInfo.count, 1)
        XCTAssertEqual(content.userInfo["makosh.telegram.token"] as? String, "opaque-uuid")
        XCTAssertNotNil(content.sound); XCTAssertTrue(content.attachments.isEmpty)
        XCTAssertTrue(content.categoryIdentifier.isEmpty)
        let silent = telegramSystemNotificationContent(.init(id: "other", title: "Telegram", body: "Новое сообщение", sound: false, bounce: false))
        XCTAssertNil(silent.sound)
    }
    func testLateCleanupCannotRemoveNewlySubmittedCardOrOtherServiceNotifications() {
        XCTAssertEqual(telegramNotificationIDsToClear(["makosh.telegram.old", "mail.other", "makosh.telegram.new"],
            keeping: ["makosh.telegram.new"]), ["makosh.telegram.old"])
    }
    func testSecondWorkspaceCannotStealFirstWorkspaceRouteAndSameAccountBadgeIsCountedOnce() throws {
        let suite = "org.makosh.notification-registry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let first = TelegramNotificationController(defaults: defaults), second = TelegramNotificationController(defaults: defaults)
        first.bind(accountID: 1); second.bind(accountID: 1)
        first.environment = { .init(now: Date(timeIntervalSince1970: 2_000)) }
        var firstActivations = 0, secondActivations = 0
        let registry = TelegramNotificationRegistry()
        _ = registry.register(first) { firstActivations += 1 }
        let secondRegistration = registry.register(second) { secondActivations += 1 }
        XCTAssertTrue(registry.admitDelivery(controller: first, identity: "1:7:0:message:1"))
        XCTAssertFalse(registry.admitDelivery(controller: second, identity: "1:7:0:message:1"))
        XCTAssertTrue(registry.admitDelivery(controller: second, identity: "1:7:0:message:2"))
        first.didActivate = { _ in true }
        first.receive(.init(accountID: 1, peerID: 7, namespace: 0, messageID: 1, threadID: nil, timestamp: 1_999,
            category: .personal, title: "Alice", text: try .init(text: "Hello"), fallback: "Новое сообщение",
            incoming: true, serverNotify: true, serverPreviews: true, serverSilent: false,
            secret: false, protected: false, serviceCodes: false), contextID: first.contextID)
        let id = try XCTUnwrap(first.delivery?.id)
        XCTAssertTrue(registry.canPresent(identifier: id)); XCTAssertTrue(registry.identifiers.contains(id))
        XCTAssertTrue(registry.activate(identifier: id)); XCTAssertEqual(firstActivations, 1); XCTAssertEqual(secondActivations, 0)
        XCTAssertFalse(registry.activate(identifier: id))
        first.receiveUnread([.personal: .init(messages: 7, chats: 2)], contextID: first.contextID)
        second.receiveUnread([.personal: .init(messages: 5, chats: 1)], contextID: second.contextID)
        XCTAssertEqual(registry.badgeCount, 7)
        registry.unregister(secondRegistration); XCTAssertEqual(registry.badgeCount, 7)
    }
}
