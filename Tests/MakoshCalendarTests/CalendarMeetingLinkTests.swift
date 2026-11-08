import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarMeetingLinkTests: XCTestCase {
    func testFindsTelemostLinks() {
        XCTAssertEqual(
            CalendarMeetingLink.telemost(in: "Ссылка: https://telemost.yandex.ru/j/123 — ждём")?.absoluteString,
            "https://telemost.yandex.ru/j/123")
        XCTAssertEqual(CalendarMeetingLink.telemost(in: "https://telemost.360.yandex.ru/j/9")?.host, "telemost.360.yandex.ru")
        XCTAssertNil(CalendarMeetingLink.telemost(in: "без ссылки"))
    }

    func testIgnoresLookalikeHosts() {
        XCTAssertNil(CalendarMeetingLink.telemost(in: "https://telemost.yandex.ru.evil.test/j/1"))
        XCTAssertNil(CalendarMeetingLink.telemost(in: "http://telemost.yandex.ru/j/1"), "plain HTTP is not a meeting link")
        XCTAssertNil(CalendarMeetingLink.telemost(in: "https://evil-telemost.yandex.ru.test/j/1"))
    }
}
