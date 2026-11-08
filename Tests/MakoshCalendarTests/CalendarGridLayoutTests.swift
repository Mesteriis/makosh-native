import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarGridLayoutTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }
    private let day = Date(timeIntervalSince1970: 1_794_096_000)  // 2026-11-08 00:00Z, a Sunday
    private func occurrence(_ from: Double, _ to: Double) -> CalendarOccurrence {
        let start = day.addingTimeInterval(from * 3600)
        return CalendarOccurrence(
            eventID: UUID(), collectionID: UUID(), time: .timed(start: start, end: day.addingTimeInterval(to * 3600), timeZone: nil),
            key: start)
    }

    func testOverlapsShareColumns() {
        let a = occurrence(10, 11), b = occurrence(10.5, 12), c = occurrence(11, 11.5)
        let items = CalendarGridLayout.layout(day: day, occurrences: [c, b, a], calendar: utc)
        let byEvent = Dictionary(uniqueKeysWithValues: items.map { ($0.occurrence.eventID, $0) })
        XCTAssertEqual(byEvent[a.eventID]?.column, 0)
        XCTAssertEqual(byEvent[b.eventID]?.column, 1)
        XCTAssertEqual(byEvent[c.eventID]?.column, 0)
        XCTAssertEqual(Set(items.map(\.columns)), [2])
        XCTAssertEqual(byEvent[b.eventID]?.startMinute, 630)
        XCTAssertEqual(byEvent[b.eventID]?.endMinute, 720)
    }

    func testSeparateClustersKeepOneColumn() {
        let items = CalendarGridLayout.layout(day: day, occurrences: [occurrence(9, 10), occurrence(13, 14)], calendar: utc)
        XCTAssertEqual(items.map(\.columns), [1, 1])
    }

    func testMidnightSplit() {
        let late = occurrence(23, 25)
        let first = CalendarGridLayout.layout(day: day, occurrences: [late], calendar: utc)
        XCTAssertEqual(first.map(\.startMinute), [1380])
        XCTAssertEqual(first.map(\.endMinute), [1440])
        XCTAssertEqual(first.first?.clippedBottom, true)
        let next = CalendarGridLayout.layout(day: day.addingTimeInterval(86400), occurrences: [late], calendar: utc)
        XCTAssertEqual(next.map(\.startMinute), [0])
        XCTAssertEqual(next.map(\.endMinute), [60])
        XCTAssertEqual(next.first?.clippedTop, true)
    }

    func testAllDayOccurrencesStayOutOfTheGrid() {
        let allDay = CalendarOccurrence(
            eventID: UUID(), collectionID: UUID(),
            time: .allDay(start: CalendarDay(year: 2026, month: 11, day: 8), endExclusive: CalendarDay(year: 2026, month: 11, day: 9)),
            key: day)
        XCTAssertTrue(CalendarGridLayout.layout(day: day, occurrences: [allDay], calendar: utc).isEmpty)
    }

    func testWeekStartsOnPreference() {
        let week = CalendarPeriod(mode: .week, anchor: day).interval(calendar: utc)
        XCTAssertEqual(week.start, day.addingTimeInterval(-6 * 86400), "Monday 2 November")
        XCTAssertEqual(week.duration, 7 * 86400)
        XCTAssertEqual(CalendarPeriod(mode: .week, anchor: day).days(calendar: utc).count, 7)
        var sunday = utc
        sunday.firstWeekday = 1
        XCTAssertEqual(CalendarPeriod(mode: .week, anchor: day).interval(calendar: sunday).start, day)
    }

    func testMoveByMonthClampsDay() {
        let january31 = Date(timeIntervalSince1970: 1_801_353_600)  // 2027-01-31 00:00Z
        let moved = CalendarPeriod(mode: .month, anchor: january31).moved(by: 1, calendar: utc)
        XCTAssertEqual(utc.dateComponents([.month, .day], from: moved.anchor), DateComponents(month: 2, day: 28))
        XCTAssertEqual(CalendarPeriod(mode: .day, anchor: day).moved(by: -1, calendar: utc).anchor, day.addingTimeInterval(-86400))
        XCTAssertEqual(CalendarPeriod(mode: .week, anchor: day).moved(by: 2, calendar: utc).anchor, day.addingTimeInterval(14 * 86400))
        XCTAssertEqual(CalendarPeriod(mode: .month, anchor: day).days(calendar: utc).count, 30)
    }

    func testAllDaySpansDays() {
        let trip = CalendarOccurrence(
            eventID: UUID(), collectionID: UUID(),
            time: .allDay(start: CalendarDay(year: 2026, month: 11, day: 9), endExclusive: CalendarDay(year: 2026, month: 11, day: 12)),
            key: day)
        let days = (0..<6).map { day.addingTimeInterval(Double($0) * 86400) }
        let rows = CalendarGridLayout.allDay(days: days, occurrences: [trip, occurrence(10, 11)], calendar: utc)
        XCTAssertEqual(rows.map(\.count), [0, 1, 1, 1, 0, 0])
    }
}
