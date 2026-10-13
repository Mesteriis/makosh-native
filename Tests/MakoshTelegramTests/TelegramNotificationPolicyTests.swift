import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramNotificationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)
    private func event(incoming: Bool = true, notify: Bool = true, previews: Bool = true,
                       silent: Bool = false, secret: Bool = false, protected: Bool = false,
                       codes: Bool = false, timestamp: Int32 = 1_999, text: TelegramFormattedText? = nil) -> TelegramNotificationEvent {
        .init(accountID: 1, peerID: 42, namespace: 0, messageID: 7, threadID: nil, timestamp: timestamp,
              category: .personal, title: "Alice", text: text ?? (try? .init(text: "Hello 12345")), fallback: "Фото",
              incoming: incoming, serverNotify: notify, serverPreviews: previews, serverSilent: silent,
              secret: secret, protected: protected, serviceCodes: codes)
    }
    private func project(_ event: TelegramNotificationEvent, _ preferences: TelegramNotificationPreferences = .init(),
                         active: Bool = false, locked: Bool = false) -> TelegramNotificationContent? {
        telegramNotificationContent(event, preferences: preferences, environment: .init(active: active, locked: locked, now: now))
    }
    func testIncomingUsesContentAndDefaultSoundButOutgoingServerMuteAndExpiredEventsNeverNotify() {
        XCTAssertEqual(project(event()), .init(title: "Alice", body: "Hello 12345", sound: true, bounce: false))
        XCTAssertNil(project(event(incoming: false)))
        XCTAssertNil(project(event(notify: false)))
        XCTAssertNil(project(event(timestamp: -100_000)))
        XCTAssertNil(project(event(timestamp: 2_100)))
    }
    func testDisabledMasterSnoozeAndActiveWindowSuppressWithoutChangingEvent() {
        var p = TelegramNotificationPreferences(); p.enabled = false
        p.peers[42] = .init(enabled: true)
        XCTAssertNil(project(event(), p))
        p.enabled = true; p.snoozeUntil = now.addingTimeInterval(1)
        XCTAssertNil(project(event(), p))
        p.snoozeUntil = now
        XCTAssertNotNil(project(event(), p))
        XCTAssertNil(project(event(), p, active: true))
        p.suppressWhileActive = false
        XCTAssertNotNil(project(event(), p, active: true))
    }
    func testPeerOverridesCategoryButCannotOverrideServerPrivacyOrSilentFlag() {
        var p = TelegramNotificationPreferences(); p.categories[.personal] = .init(enabled: false, previews: false, sound: TelegramNotificationSound.none)
        XCTAssertNil(project(event(), p))
        p.peers[42] = .init(enabled: true, previews: true, sound: .system)
        XCTAssertEqual(project(event(), p)?.body, "Hello 12345")
        XCTAssertEqual(project(event(), p)?.sound, true)
        XCTAssertEqual(project(event(previews: false), p)?.body, "Новое сообщение")
        XCTAssertEqual(project(event(silent: true), p)?.sound, false)
        XCTAssertNil(project(event(notify: false), p))
    }
    func testLockSecretProtectedAndPreviewOffNeverExposeMessage() {
        XCTAssertEqual(project(event(), locked: true), .init(title: "Telegram", body: "Новое сообщение", sound: false, bounce: false))
        XCTAssertEqual(project(event(secret: true))?.body, "Новое сообщение")
        XCTAssertEqual(project(event(protected: true))?.body, "Новое сообщение")
        var p = TelegramNotificationPreferences(); p.previews = false
        XCTAssertEqual(project(event(), p)?.body, "Новое сообщение")
    }
    func testSpoilersAndServiceCodesAreMaskedAndMissingFormattingNeverFallsBackToRawText() throws {
        let text = try TelegramFormattedText(text: "Hello secret", entities: [.init(offset: 6, length: 6, kind: .spoiler)])
        XCTAssertEqual(project(event(text: text))?.body, "Hello ██████")
        XCTAssertEqual(project(event(codes: true))?.body, "Hello █████")
        let missing = TelegramNotificationEvent(accountID: 1, peerID: 42, namespace: 0, messageID: 8, threadID: nil,
            timestamp: 1_999, category: .personal, title: "Alice", text: nil, fallback: "Вложение", incoming: true,
            serverNotify: true, serverPreviews: true, serverSilent: false, secret: false, protected: false, serviceCodes: false)
        XCTAssertEqual(project(missing)?.body, "Вложение")
    }
    func testEmptyMediaCaptionUsesMediaSummaryRatherThanEmptyText() throws {
        XCTAssertEqual(project(event(text: try .init(text: "")))?.body, "Фото")
    }
}
