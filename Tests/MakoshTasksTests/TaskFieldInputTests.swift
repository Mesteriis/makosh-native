import Foundation
import XCTest
@testable import MakoshTasks

final class TaskFieldInputTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }

    func testURLNormalization() {
        XCTAssertEqual(TaskFieldInput.url("example.com/a"), URL(string: "https://example.com/a"))
        XCTAssertEqual(TaskFieldInput.url(" https://example.com "), URL(string: "https://example.com"))
        XCTAssertEqual(TaskFieldInput.url("http://x.y"), URL(string: "http://x.y"))
        XCTAssertNil(TaskFieldInput.url("not a url"))
        XCTAssertNil(TaskFieldInput.url(""))
        XCTAssertNil(TaskFieldInput.url("https://"))
    }

    func testEstimateParsing() {
        XCTAssertEqual(TaskFieldInput.estimateMinutes("1.5h"), 90)
        XCTAssertEqual(TaskFieldInput.estimateMinutes("1,5 ч"), 90)
        XCTAssertEqual(TaskFieldInput.estimateMinutes("1 hour"), 60)
        XCTAssertEqual(TaskFieldInput.estimateMinutes("2 hours"), 120)
        XCTAssertEqual(TaskFieldInput.estimateMinutes("30 мин"), 30)
        XCTAssertEqual(TaskFieldInput.estimateMinutes("30 min"), 30)
        XCTAssertEqual(TaskFieldInput.estimateMinutes("45"), 45)
        XCTAssertEqual(TaskFieldInput.estimateMinutes("2 ч 15 мин"), 135)
        XCTAssertNil(TaskFieldInput.estimateMinutes("x"))
        XCTAssertNil(TaskFieldInput.estimateMinutes("0"))
        XCTAssertNil(TaskFieldInput.estimateMinutes(""))
    }

    func testEstimateText() {
        XCTAssertEqual(TaskFieldInput.estimateText(90), "1,5 ч")
        XCTAssertEqual(TaskFieldInput.estimateText(30), "30 мин")
        XCTAssertEqual(TaskFieldInput.estimateText(120), "2 ч")
        XCTAssertEqual(TaskFieldInput.estimateText(135), "2 ч 15 мин")
        XCTAssertEqual(TaskFieldInput.estimateText(0), "")
    }

    func testDateInputAcceptsQuickEntryAndNumericForms() {
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7))!
        XCTAssertEqual(TaskFieldInput.date("завтра", today: today, calendar: calendar), calendar.date(byAdding: .day, value: 1, to: today))
        XCTAssertEqual(
            TaskFieldInput.date("20.04.2027", today: today, calendar: calendar),
            calendar.date(from: DateComponents(year: 2027, month: 4, day: 20)))
        XCTAssertEqual(
            TaskFieldInput.date("2027-04-20", today: today, calendar: calendar),
            calendar.date(from: DateComponents(year: 2027, month: 4, day: 20)))
        XCTAssertNil(TaskFieldInput.date("когда-нибудь", today: today, calendar: calendar))
        XCTAssertNil(TaskFieldInput.date("", today: today, calendar: calendar))
    }

    func testPersonasSplitAndStripSpaces() {
        XCTAssertEqual(TaskFieldInput.personas("Боб, /Алиса , Иван Иванов"), ["Боб", "Алиса", "ИванИванов"])
        XCTAssertEqual(TaskFieldInput.personas(" , "), [])
    }
}
