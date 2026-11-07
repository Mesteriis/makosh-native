import Foundation
import XCTest
@testable import MakoshTasks

final class TaskCalendarTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }

    func testMonthCellsStartOnConfiguredWeekday() {
        let november = TaskCalendarMonth.make(year: 2026, month: 11, firstWeekday: 2, calendar: calendar)
        XCTAssertEqual(november.cells.prefix(6).compactMap { $0 }.count, 0, "1 November 2026 is a Sunday: six leading blanks")
        XCTAssertEqual(november.cells[6], day(2026, 11, 1))
        XCTAssertEqual(november.cells.compactMap { $0 }.count, 30)
        XCTAssertEqual(november.cells.count % 7, 0)
        XCTAssertEqual(november.weekdayTitles, ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"])
        let sundayFirst = TaskCalendarMonth.make(year: 2026, month: 11, firstWeekday: 1, calendar: calendar)
        XCTAssertEqual(sundayFirst.cells[0], day(2026, 11, 1))
        XCTAssertEqual(sundayFirst.weekdayTitles.first, "Вс")
        XCTAssertEqual(november.title, "Ноябрь 2026")
        XCTAssertEqual(november.next().month, 12)
        XCTAssertEqual(november.previous().month, 10)
        let december = november.next()
        XCTAssertEqual(december.next().year, 2027)
        XCTAssertEqual(december.next().month, 1)
    }

    func testDueDaysAndAgendaRange() {
        let tasks = [
            Task(title: "a", due: day(2026, 11, 20)), Task(title: "b", due: day(2026, 11, 20).addingTimeInterval(3600)),
            Task(title: "c", status: .done, due: day(2026, 11, 21)), Task(title: "d"),
        ]
        XCTAssertEqual(TaskCalendarRules.dueDays(tasks, calendar: calendar), [day(2026, 11, 20), day(2026, 11, 21)])
        let today = day(2026, 11, 7)
        XCTAssertEqual(TaskCalendarRules.agendaRange(.today, today: today, calendar: calendar), today...today)
        XCTAssertEqual(TaskCalendarRules.agendaRange(.tomorrow, today: today, calendar: calendar), today...day(2026, 11, 8))
        XCTAssertEqual(TaskCalendarRules.agendaRange(.week, today: today, calendar: calendar), today...day(2026, 11, 14))
        XCTAssertEqual(TaskCalendarRules.agendaRange(.month, today: today, calendar: calendar), today...day(2026, 12, 7))
        XCTAssertNil(TaskCalendarRules.agendaRange(.overdue, today: today, calendar: calendar))
        XCTAssertNil(TaskCalendarRules.agendaRange(nil, today: today, calendar: calendar))
    }

    func testDateFormats() {
        let date = day(2026, 4, 20)
        XCTAssertEqual(TaskDateFormat.iso.string(date, calendar: calendar), "2026-04-20")
        XCTAssertEqual(TaskDateFormat.dmy.string(date, calendar: calendar), "20.04.2026")
        XCTAssertEqual(TaskDateFormat.short.string(date, calendar: calendar), "20 апр.")
        XCTAssertEqual(TaskDateFormat.long.string(date, calendar: calendar), "20 апреля 2026")
    }
}
