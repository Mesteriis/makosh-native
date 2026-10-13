import XCTest
import Combine
@testable import MakoshTelegram

@MainActor final class TelegramNotificationControllerTests: XCTestCase {
    private func controller() -> TelegramNotificationController {
        let suite = "org.makosh.notification-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let result = TelegramNotificationController(defaults: defaults)
        result.environment = { .init(now: Date(timeIntervalSince1970: 2_000)) }
        return result
    }
    private func event(account: Int64 = 1, message: Int32 = 7) -> TelegramNotificationEvent {
        .init(accountID: account, peerID: 42, namespace: 0, messageID: message, threadID: nil, timestamp: 1_999,
              category: .personal, title: "Alice", text: try? .init(text: "Hello"), fallback: "Вложение",
              incoming: true, serverNotify: true, serverPreviews: true, serverSilent: false,
              secret: false, protected: false, serviceCodes: false)
    }
    func testDuplicateEventsAndOldContextNeverPublishAndRebindRetainsSameAccountDeduplication() {
        let c = controller(); c.bind(accountID: 1)
        var delivered: [TelegramNotificationDelivery] = []
        let observation = c.$delivery.compactMap { $0 }.sink { delivered.append($0) }; defer { observation.cancel() }
        let first = c.contextID
        c.receive(event(), contextID: first); c.receive(event(), contextID: first)
        XCTAssertEqual(delivered.count, 1)
        c.bind(accountID: nil); c.bind(accountID: 1)
        c.receive(event(message: 8), contextID: first)
        c.receive(event(), contextID: c.contextID)
        XCTAssertEqual(delivered.count, 1)
        c.receive(event(message: 8), contextID: c.contextID)
        XCTAssertEqual(delivered.count, 2)
        c.receive(event(account: 2, message: 9), contextID: c.contextID)
        XCTAssertEqual(delivered.count, 2)
    }
    func testSettingsAreAccountScopedAndStaleEditorCannotWriteOrReset() {
        let c = controller(); c.bind(accountID: 1); let first = c.contextID
        var p = c.preferences; p.previews = false; p.peers[42] = .init(enabled: false)
        XCTAssertTrue(c.update(p, contextID: first))
        c.bind(accountID: 2); XCTAssertTrue(c.preferences.previews); XCTAssertTrue(c.preferences.peers.isEmpty)
        XCTAssertFalse(c.update(p, contextID: first)); XCTAssertFalse(c.reset(contextID: first))
        c.bind(accountID: 1); XCTAssertFalse(c.preferences.previews); XCTAssertEqual(c.preferences.peers[42]?.enabled, false)
        XCTAssertTrue(c.reset(contextID: c.contextID)); XCTAssertTrue(c.preferences.previews); XCTAssertTrue(c.preferences.peers.isEmpty)
    }
    func testActivationIsSingleUseAccountBoundAndDisabledAfterChangingPrivacy() throws {
        let c = controller(); c.bind(accountID: 1)
        c.didActivate = { $0.peerID == 42 && $0.messageID == 7 }
        c.receive(event(), contextID: c.contextID)
        let id = try XCTUnwrap(c.delivery?.id)
        XCTAssertTrue(c.activate(identifier: id)); XCTAssertFalse(c.activate(identifier: id))
        c.receive(event(message: 8), contextID: c.contextID)
        let oldID = try XCTUnwrap(c.delivery?.id)
        var p = c.preferences; p.previews = false
        XCTAssertTrue(c.update(p, contextID: c.contextID))
        XCTAssertFalse(c.activate(identifier: oldID))
        c.bind(accountID: 2); XCTAssertFalse(c.activate(identifier: oldID))
    }
    func testBadgeCountsUseWholeNativeCategoriesAndRecalculateOnSettingsWithoutChatListPages() {
        let c = controller(); c.bind(accountID: 1)
        c.receiveUnread([.personal: .init(messages: 12, chats: 2), .groups: .init(messages: 50, chats: 3),
                         .channels: .init(messages: 200, chats: 4)], contextID: c.contextID)
        XCTAssertEqual(c.badgeCount, 262)
        var p = c.preferences; p.badgeChannels = false; p.countMessages = false
        XCTAssertTrue(c.update(p, contextID: c.contextID)); XCTAssertEqual(c.badgeCount, 5)
        let old = c.contextID; c.bind(accountID: 2)
        c.receiveUnread([.personal: .init(messages: 999, chats: 99)], contextID: old)
        XCTAssertEqual(c.badgeCount, 0)
        p.badgeEnabled = false; XCTAssertTrue(c.update(p, contextID: c.contextID)); XCTAssertEqual(c.badgeCount, 0)
    }
    func testCorruptPreferencesFailClosedUntilExplicitResetAndSurviveControllerRecreation() {
        let suite = "org.makosh.notification-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("broken".utf8), forKey: "telegram.notifications.v1.1")
        let c = TelegramNotificationController(defaults: defaults); c.bind(accountID: 1)
        XCTAssertNotNil(c.error); XCTAssertFalse(c.preferences.enabled)
        XCTAssertFalse(c.update(.init(), contextID: c.contextID))
        XCTAssertTrue(c.reset(contextID: c.contextID)); XCTAssertNil(c.error)
        var p = c.preferences; p.previews = false
        XCTAssertTrue(c.update(p, contextID: c.contextID))
        let reopened = TelegramNotificationController(defaults: defaults); reopened.bind(accountID: 1)
        XCTAssertFalse(reopened.preferences.previews); XCTAssertNil(reopened.error)
    }
    func testLockClearsExistingRoutesAndNewPresentationsCannotBorrowInactiveWindowState() throws {
        let c = controller(); c.bind(accountID: 1)
        c.receive(event(), contextID: c.contextID)
        let id = try XCTUnwrap(c.delivery?.id)
        XCTAssertTrue(c.canPresent(identifier: id))
        c.setPresentationEnvironment(active: true, locked: false)
        XCTAssertFalse(c.canPresent(identifier: id))
        c.setPresentationEnvironment(active: false, locked: true)
        XCTAssertFalse(c.activate(identifier: id)); XCTAssertNil(c.delivery)
    }
    func testPrivacyChangesPropagateToOtherWindowsOfSameAccountButNotOtherAccounts() {
        let suite = "org.makosh.notification-windows.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let first = TelegramNotificationController(defaults: defaults), second = TelegramNotificationController(defaults: defaults), third = TelegramNotificationController(defaults: defaults)
        first.bind(accountID: 1); second.bind(accountID: 1); third.bind(accountID: 2)
        var p = first.preferences; p.previews = false
        XCTAssertTrue(first.update(p, contextID: first.contextID))
        XCTAssertFalse(second.preferences.previews); XCTAssertTrue(third.preferences.previews)
        XCTAssertTrue(first.reset(contextID: first.contextID)); XCTAssertTrue(second.preferences.previews)
    }
}
