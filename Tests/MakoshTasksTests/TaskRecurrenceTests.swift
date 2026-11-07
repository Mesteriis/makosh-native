import Foundation
import XCTest
@testable import MakoshTasks

final class TaskRecurrenceTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }
    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
    }

    func testNormalizeAcceptsSimpleAndRRule() {
        XCTAssertEqual(TaskRecurrence.normalize("Weekly "), "weekly")
        XCTAssertEqual(TaskRecurrence.normalize("biweekly"), "biweekly")
        XCTAssertEqual(TaskRecurrence.normalize("FREQ=MONTHLY;INTERVAL=2"), "FREQ=MONTHLY;INTERVAL=2")
        XCTAssertEqual(TaskRecurrence.normalize("RRULE:FREQ=DAILY"), "FREQ=DAILY")
        XCTAssertNil(TaskRecurrence.normalize("каждый"))
        XCTAssertNil(TaskRecurrence.normalize(""))
    }

    func testHumanTextRussian() {
        XCTAssertEqual(TaskRecurrence.humanText("daily"), "Каждый день")
        XCTAssertEqual(TaskRecurrence.humanText("biweekly"), "Каждые 2 недели")
        XCTAssertEqual(TaskRecurrence.humanText("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE"), "Каждые 2 недели: Пн, Ср")
        XCTAssertEqual(TaskRecurrence.humanText("FREQ=MONTHLY;BYDAY=1MO"), "Первый Пн каждого месяца")
        XCTAssertEqual(TaskRecurrence.humanText("FREQ=YEARLY;BYMONTH=1"), "Каждый год (янв)")
        XCTAssertEqual(TaskRecurrence.humanText("FREQ=DAILY;INTERVAL=3"), "Каждые 3 дня")
        XCTAssertEqual(TaskRecurrence.humanText("FREQ=DAILY;INTERVAL=5"), "Каждые 5 дней")
        XCTAssertEqual(TaskRecurrence.humanText("strange"), "strange")
        XCTAssertNil(TaskRecurrence.humanText(nil))
    }

    func testNextDueCountsFromTodayNotFromDue() {
        let next = TaskRecurrence.nextDue("weekly", today: today, calendar: calendar)
        XCTAssertEqual(next, calendar.date(from: DateComponents(year: 2026, month: 11, day: 14)))
        XCTAssertEqual(
            TaskRecurrence.nextDue("FREQ=MONTHLY;INTERVAL=2", today: today, calendar: calendar),
            calendar.date(from: DateComponents(year: 2027, month: 1, day: 7)))
        XCTAssertEqual(
            TaskRecurrence.nextDue("biweekly", today: today, calendar: calendar),
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 21)))
        XCTAssertNil(TaskRecurrence.nextDue("FREQ=HOURLY", today: today, calendar: calendar))
    }

    func testSpawnIDIsDeterministic() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(TaskRecurrence.spawnID(for: a), TaskRecurrence.spawnID(for: a))
        XCTAssertNotEqual(TaskRecurrence.spawnID(for: a), TaskRecurrence.spawnID(for: b))
        XCTAssertNotEqual(TaskRecurrence.spawnID(for: a), a)
        let bytes = TaskRecurrence.spawnID(for: a).uuid
        XCTAssertEqual(bytes.6 >> 4, 5, "version 5")
        XCTAssertEqual(bytes.8 & 0xC0, 0x80, "RFC 4122 variant")
    }
}
