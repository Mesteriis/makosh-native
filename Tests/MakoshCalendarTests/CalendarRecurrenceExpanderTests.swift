import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarRecurrenceExpanderTests: XCTestCase {
    private let iso = ISO8601DateFormatter()
    private func date(_ text: String) -> Date { iso.date(from: text)! }
    private func timed(_ start: String, minutes: Int = 60, zone: String? = nil, rule: String?, exdates: [String] = []) -> CalendarEvent {
        let from = date(start)
        return CalendarEvent(
            collectionID: UUID(), uid: "s", title: "Серия",
            time: .timed(start: from, end: from.addingTimeInterval(TimeInterval(minutes * 60)), timeZone: zone),
            recurrence: rule.map { CalendarRecurrence(rrule: $0, exdates: exdates.map(date)) })
    }
    private func window(_ from: String, _ to: String) -> DateInterval { DateInterval(start: date(from), end: date(to)) }

    func testWeeklyKeepsLocalTimeAcrossDST() {
        // Berlin leaves summer time on 2026-10-25; Mondays at 10:00 local from 2026-10-19 (08:00Z).
        let master = timed("2026-10-19T08:00:00Z", zone: "Europe/Berlin", rule: "FREQ=WEEKLY;BYDAY=MO")
        let occurrences = CalendarRecurrenceExpander.occurrences(
            of: master, overrides: [], in: window("2026-10-19T00:00:00Z", "2026-11-10T00:00:00Z"))
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(occurrences.map { berlin.component(.hour, from: $0.start) }, [10, 10, 10, 10])
        XCTAssertEqual(occurrences.map { berlin.component(.day, from: $0.start) }, [19, 26, 2, 9])
        XCTAssertEqual(occurrences.map { $0.end.timeIntervalSince($0.start) }, [3600, 3600, 3600, 3600])
    }

    func testCountUntilInterval() {
        let counted = CalendarRecurrenceExpander.occurrences(
            of: timed("2026-11-01T09:00:00Z", rule: "FREQ=DAILY;INTERVAL=2;COUNT=3"), overrides: [],
            in: window("2026-10-01T00:00:00Z", "2027-01-01T00:00:00Z"))
        XCTAssertEqual(counted.map(\.start), ["2026-11-01T09:00:00Z", "2026-11-03T09:00:00Z", "2026-11-05T09:00:00Z"].map(date))
        let until = CalendarRecurrenceExpander.occurrences(
            of: timed("2026-11-01T09:00:00Z", rule: "FREQ=DAILY;UNTIL=20261105T090000Z"), overrides: [],
            in: window("2026-10-01T00:00:00Z", "2027-01-01T00:00:00Z"))
        XCTAssertEqual(until.count, 5)
    }

    func testCountIncludesExcludedDates() {
        let occurrences = CalendarRecurrenceExpander.occurrences(
            of: timed("2026-11-01T09:00:00Z", rule: "FREQ=DAILY;COUNT=3", exdates: ["2026-11-02T09:00:00Z"]), overrides: [],
            in: window("2026-10-01T00:00:00Z", "2027-01-01T00:00:00Z"))
        XCTAssertEqual(occurrences.map(\.start), ["2026-11-01T09:00:00Z", "2026-11-03T09:00:00Z"].map(date))
    }

    func testMonthlyLastFriday() {
        let occurrences = CalendarRecurrenceExpander.occurrences(
            of: timed("2026-11-27T12:00:00Z", rule: "FREQ=MONTHLY;BYDAY=-1FR"), overrides: [],
            in: window("2026-11-01T00:00:00Z", "2027-01-01T00:00:00Z"))
        XCTAssertEqual(occurrences.map(\.start), ["2026-11-27T12:00:00Z", "2026-12-25T12:00:00Z"].map(date))
    }

    func testMonthlyByMonthDayNegativeAndWeeklyMultipleDays() {
        let lastDay = CalendarRecurrenceExpander.occurrences(
            of: timed("2026-11-30T12:00:00Z", rule: "FREQ=MONTHLY;BYMONTHDAY=-1"), overrides: [],
            in: window("2026-11-01T00:00:00Z", "2027-03-01T00:00:00Z"))
        XCTAssertEqual(
            lastDay.map(\.start),
            ["2026-11-30T12:00:00Z", "2026-12-31T12:00:00Z", "2027-01-31T12:00:00Z", "2027-02-28T12:00:00Z"].map(date))
        let weekdays = CalendarRecurrenceExpander.occurrences(
            of: timed("2026-11-09T09:00:00Z", rule: "FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=4"), overrides: [],
            in: window("2026-11-01T00:00:00Z", "2026-12-01T00:00:00Z"))
        XCTAssertEqual(
            weekdays.map(\.start),
            ["2026-11-09T09:00:00Z", "2026-11-11T09:00:00Z", "2026-11-13T09:00:00Z", "2026-11-16T09:00:00Z"].map(date))
    }

    func testExdateAndOverridesReplaceOccurrences() {
        let master = timed("2026-11-09T09:00:00Z", rule: "FREQ=WEEKLY", exdates: ["2026-11-16T09:00:00Z"])
        var moved = timed("2026-11-23T10:00:00Z", rule: nil)
        moved.uid = master.uid
        moved.recurrenceID = date("2026-11-23T09:00:00Z")
        var cancelled = timed("2026-11-30T09:00:00Z", rule: nil)
        cancelled.recurrenceID = date("2026-11-30T09:00:00Z")
        cancelled.status = .cancelled
        let occurrences = CalendarRecurrenceExpander.occurrences(
            of: master, overrides: [moved, cancelled], in: window("2026-11-09T00:00:00Z", "2026-12-08T00:00:00Z"))
        XCTAssertEqual(occurrences.map(\.key), ["2026-11-09T09:00:00Z", "2026-11-23T09:00:00Z", "2026-12-07T09:00:00Z"].map(date))
        XCTAssertEqual(occurrences[1].start, date("2026-11-23T10:00:00Z"))
        XCTAssertEqual(occurrences[1].eventID, moved.id)
        XCTAssertEqual(occurrences[0].eventID, master.id)
    }

    func testAllDayYearly() {
        let master = CalendarEvent(
            collectionID: UUID(), uid: "b", title: "День рождения",
            time: .allDay(start: CalendarDay(year: 2026, month: 11, day: 20), endExclusive: CalendarDay(year: 2026, month: 11, day: 21)),
            recurrence: CalendarRecurrence(rrule: "FREQ=YEARLY"))
        let occurrences = CalendarRecurrenceExpander.occurrences(
            of: master, overrides: [], in: window("2026-01-01T00:00:00Z", "2028-12-31T00:00:00Z"))
        XCTAssertEqual(
            occurrences.map(\.time),
            [2026, 2027, 2028].map {
                .allDay(start: CalendarDay(year: $0, month: 11, day: 20), endExclusive: CalendarDay(year: $0, month: 11, day: 21))
            })
    }

    func testSingleEventOnlyWhenOverlapping() {
        let single = timed("2026-11-10T09:00:00Z", rule: nil)
        XCTAssertEqual(
            CalendarRecurrenceExpander.occurrences(of: single, overrides: [], in: window("2026-11-10T09:30:00Z", "2026-11-11T00:00:00Z"))
                .count,
            1)
        XCTAssertTrue(
            CalendarRecurrenceExpander.occurrences(of: single, overrides: [], in: window("2026-11-10T10:00:00Z", "2026-11-11T00:00:00Z"))
                .isEmpty)
    }

    func testUnsupportedRuleYieldsFirstOnly() {
        let rule = "FREQ=MONTHLY;BYSETPOS=-1;BYDAY=MO,TU"
        let occurrences = CalendarRecurrenceExpander.occurrences(
            of: timed("2026-11-30T09:00:00Z", rule: rule), overrides: [], in: window("2026-11-01T00:00:00Z", "2027-06-01T00:00:00Z"))
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertTrue(CalendarRecurrenceExpander.unsupported(rrule: rule))
        XCTAssertFalse(CalendarRecurrenceExpander.unsupported(rrule: "FREQ=WEEKLY;BYDAY=MO"))
    }

    func testSafetyCap() {
        let occurrences = CalendarRecurrenceExpander.occurrences(
            of: timed("2026-01-01T09:00:00Z", rule: "FREQ=DAILY"), overrides: [], in: window("2026-01-01T00:00:00Z", "2046-01-01T00:00:00Z")
        )
        XCTAssertEqual(occurrences.count, 5000)
    }
}
