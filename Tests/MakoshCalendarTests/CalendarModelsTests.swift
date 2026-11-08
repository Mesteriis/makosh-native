import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarModelsTests: XCTestCase {
    func testGivesBusyFollowsTransparencyStatusResponseAndCopy() {
        var event = CalendarEvent.fixture(start: 10, end: 11)
        XCTAssertTrue(event.givesBusy)
        event.transparency = .free
        XCTAssertFalse(event.givesBusy)
        event.transparency = .busy
        event.status = .cancelled
        XCTAssertFalse(event.givesBusy)
        event.status = .tentative
        XCTAssertTrue(event.givesBusy)
        event.attendees = [.init(email: "me@x.test", name: nil, response: .declined, isSelf: true, isOrganizer: false)]
        XCTAssertFalse(event.givesBusy)
        XCTAssertEqual(event.selfResponse, .declined)
        event.attendees[0].response = .needsAction
        XCTAssertTrue(event.givesBusy)
        event.busyMarker = .init(sourceEventID: UUID(), occurrenceStart: Date())
        XCTAssertTrue(event.isBusyCopy)
        XCTAssertFalse(event.givesBusy)
        event.busyMarker = nil
        event.deletedAt = Date()
        XCTAssertFalse(event.givesBusy)
    }

    func testWorkingHoursContains() {
        let hours = CalendarWorkingHours(days: [1: [540...900]])
        XCTAssertTrue(hours.contains(weekday: 1, minute: 600))
        XCTAssertFalse(hours.contains(weekday: 2, minute: 600))
        XCTAssertFalse(hours.contains(weekday: 1, minute: 901))
    }

    func testEventRoundTripsThroughJSON() throws {
        var timed = CalendarEvent.fixture(start: 9, end: 10)
        timed.attendees = [.init(email: "a@x.test", name: "А", response: .accepted, isSelf: false, isOrganizer: true)]
        timed.recurrence = CalendarRecurrence(rrule: "FREQ=WEEKLY;BYDAY=MO", exdates: [Date(timeIntervalSince1970: 1_794_000_000)])
        timed.reminders = [10]
        var allDay = CalendarEvent.fixture(start: 0, end: 1)
        allDay.time = .allDay(start: CalendarDay(year: 2026, month: 11, day: 8), endExclusive: CalendarDay(year: 2026, month: 11, day: 9))
        for event in [timed, allDay] {
            let data = try JSONEncoder().encode(event)
            XCTAssertEqual(try JSONDecoder().decode(CalendarEvent.self, from: data), event)
        }
    }

    func testCalendarDayOrdering() {
        XCTAssertLessThan(CalendarDay(year: 2026, month: 11, day: 8), CalendarDay(year: 2026, month: 11, day: 9))
        XCTAssertLessThan(CalendarDay(year: 2026, month: 10, day: 31), CalendarDay(year: 2026, month: 11, day: 1))
        XCTAssertLessThan(CalendarDay(year: 2025, month: 12, day: 31), CalendarDay(year: 2026, month: 1, day: 1))
    }
}
