import Foundation
import XCTest
@testable import MakoshTasks

/// Today is Saturday 2026-11-07 in Moscow for every case.
final class TaskDateParserTests: XCTestCase {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }()
    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)!
    }
    private var today: Date { day("2026-11-07") }
    private func parse(_ text: String) -> Date? { TaskDateParser.parse(text, today: today, calendar: calendar) }

    func testTodayTomorrowYesterdayRuAndEn() {
        XCTAssertEqual(parse("сегодня"), day("2026-11-07"))
        XCTAssertEqual(parse("Today"), day("2026-11-07"))
        XCTAssertEqual(parse("завтра"), day("2026-11-08"))
        XCTAssertEqual(parse("tomorrow"), day("2026-11-08"))
        XCTAssertEqual(parse("вчера"), day("2026-11-06"))
        XCTAssertEqual(parse("yesterday"), day("2026-11-06"))
    }

    func testWeekdayIsStrictlyAfterToday() {
        XCTAssertEqual(parse("сб"), day("2026-11-14"), "the same weekday is a week ahead")
        XCTAssertEqual(parse("пн"), day("2026-11-09"))
        XCTAssertEqual(parse("понедельник"), day("2026-11-09"))
        XCTAssertEqual(parse("mon"), day("2026-11-09"))
        XCTAssertEqual(parse("friday"), day("2026-11-13"))
        XCTAssertEqual(parse("вс"), day("2026-11-08"))
    }

    func testRelativeOffsets() {
        XCTAssertEqual(parse("+3d"), day("2026-11-10"))
        XCTAssertEqual(parse("+2w"), day("2026-11-21"))
        XCTAssertEqual(parse("+1m"), day("2026-12-07"))
    }

    func testBareDayRollsToNextMonth() {
        XCTAssertEqual(parse("20"), day("2026-11-20"))
        XCTAssertEqual(parse("5"), day("2026-12-05"))
        XCTAssertEqual(parse("7"), day("2026-12-07"), "today's day number means next month")
        XCTAssertNil(parse("32"))
    }

    func testDayMonthRollsToNextYear() {
        XCTAssertEqual(parse("20.04"), day("2027-04-20"))
        XCTAssertEqual(parse("25/12"), day("2026-12-25"))
        XCTAssertNil(parse("31.13"))
    }

    func testFullDateAsIs() {
        XCTAssertEqual(parse("20.04.2026"), day("2026-04-20"))
        XCTAssertEqual(parse("1/2/2027"), day("2027-02-01"))
        XCTAssertEqual(parse("2026-11-30"), day("2026-11-30"))
    }

    func testMonthNames() {
        XCTAssertEqual(parse("5янв"), day("2027-01-05"))
        XCTAssertEqual(parse("jan5"), day("2027-01-05"))
        XCTAssertEqual(parse("15авг"), day("2027-08-15"))
        XCTAssertEqual(parse("дек31"), day("2026-12-31"))
    }

    func testGarbageIsNil() {
        XCTAssertNil(parse("когда-нибудь"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("+x"))
    }
}
