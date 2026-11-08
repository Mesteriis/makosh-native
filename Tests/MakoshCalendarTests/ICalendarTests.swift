import Foundation
import XCTest
@testable import MakoshCalendar

final class ICalendarTests: XCTestCase {
    private let collection = UUID()

    func testParsesFoldedTimedEventWithTZIDAttendeesAndAlarm() throws {
        let events = try ICalendar.parse(ICSFixture.timedBerlin, collectionID: collection)
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event.uid, "timed-1")
        XCTAssertEqual(event.title, "Созвон, по плану; ок")
        XCTAssertEqual(event.notes, "Первая строка\nвторая строка длинного описания, которое переносится на следующую строку")
        guard case .timed(let start, let end, let zone) = event.time else { return XCTFail("timed expected") }
        XCTAssertEqual(zone, "Europe/Berlin")
        XCTAssertEqual(end.timeIntervalSince(start), 1800)
        XCTAssertEqual(start, ISO8601DateFormatter().date(from: "2026-11-10T09:00:00Z"))
        XCTAssertEqual(event.attendees.map(\.email), ["alice@x.test", "bob@x.test"])
        XCTAssertEqual(event.attendees.map(\.response), [.accepted, .needsAction])
        XCTAssertEqual(event.attendees.first?.isOrganizer, true)
        XCTAssertEqual(event.organizerEmail, "alice@x.test")
        XCTAssertEqual(event.reminders, [15])
        XCTAssertEqual(event.collectionID, collection)
    }

    func testParsesAllDayAndDefaultsMissingEnd() throws {
        let event = try XCTUnwrap(ICalendar.parse(ICSFixture.allDayNoEnd, collectionID: collection).first)
        XCTAssertEqual(
            event.time,
            .allDay(start: CalendarDay(year: 2026, month: 11, day: 20), endExclusive: CalendarDay(year: 2026, month: 11, day: 21)))
        XCTAssertEqual(event.transparency, .free)
    }

    func testOverrideBecomesSeparateEventWithRecurrenceID() throws {
        let events = try ICalendar.parse(ICSFixture.seriesWithOverride, collectionID: collection)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.uid)), ["series-1"])
        let master = try XCTUnwrap(events.first { $0.recurrenceID == nil })
        let override = try XCTUnwrap(events.first { $0.recurrenceID != nil })
        XCTAssertEqual(master.recurrence?.rrule, "FREQ=WEEKLY;BYDAY=MO")
        guard case .timed(let start, let end, _) = master.time else { return XCTFail() }
        XCTAssertEqual(end.timeIntervalSince(start), 45 * 60)
        XCTAssertEqual(override.recurrenceID, ISO8601DateFormatter().date(from: "2026-12-07T09:00:00Z"))
        XCTAssertEqual(override.status, .tentative)
    }

    func testExdateListAndRepeatedLines() throws {
        let master = try XCTUnwrap(
            ICalendar.parse(ICSFixture.seriesWithOverride, collectionID: collection).first { $0.recurrenceID == nil })
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(
            master.recurrence?.exdates,
            ["2026-11-16T09:00:00Z", "2026-11-23T09:00:00Z", "2026-11-30T09:00:00Z"].compactMap { iso.date(from: $0) })
    }

    func testFindsTelemostLinkInDescription() throws {
        let event = try XCTUnwrap(ICalendar.parse(ICSFixture.telemostInDescription, collectionID: collection).first)
        XCTAssertEqual(event.meetingURL?.absoluteString, "https://telemost.yandex.ru/j/12345678901234")
    }

    func testBusyCopyCarriesOnlyBusyFields() throws {
        let start = Date(timeIntervalSince1970: 1_794_200_000), end = start.addingTimeInterval(3600)
        let marker = CalendarBusyMarker(sourceEventID: UUID(), occurrenceStart: start)
        let text = ICalendar.serializeBusyCopy(uid: "copy-1", time: .timed(start: start, end: end, timeZone: nil), marker: marker)
        XCTAssertTrue(text.contains("SUMMARY:Занято"))
        XCTAssertTrue(text.contains("TRANSP:OPAQUE"))
        XCTAssertTrue(text.contains("CLASS:PRIVATE"))
        for forbidden in ["DESCRIPTION", "LOCATION", "ATTENDEE", "ORGANIZER", "VALARM", "URL"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        let parsed = try XCTUnwrap(ICalendar.parse(text, collectionID: collection).first)
        XCTAssertEqual(parsed.busyMarker, marker)
        XCTAssertEqual(parsed.time, .timed(start: start, end: end, timeZone: nil))
    }

    func testSerializeRoundTripsEvent() throws {
        let start = Date(timeIntervalSince1970: 1_794_200_400)
        var event = CalendarEvent(
            collectionID: collection, uid: "rt-1", title: "Длинное название; с запятой, и обратной \\ чертой и переносом строки",
            notes: "Строка 1\nСтрока 2", location: "Переговорная",
            time: .timed(start: start, end: start.addingTimeInterval(5400), timeZone: "Europe/Moscow"),
            recurrence: CalendarRecurrence(rrule: "FREQ=DAILY;COUNT=5", exdates: [start.addingTimeInterval(86400)]),
            attendees: [
                .init(email: "me@x.test", name: "Я", response: .accepted, isSelf: false, isOrganizer: true),
                .init(email: "bob@x.test", response: .tentative),
            ], organizerEmail: "me@x.test", reminders: [10, 60], meetingURL: URL(string: "https://telemost.yandex.ru/j/1"),
            transparency: .busy, status: .confirmed, taskID: UUID())
        event.title += String(repeating: " ещё", count: 20)
        let text = ICalendar.serialize(event)
        XCTAssertTrue(text.split(separator: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        let parsed = try XCTUnwrap(ICalendar.parse(text, collectionID: collection).first)
        XCTAssertEqual(parsed.uid, event.uid)
        XCTAssertEqual(parsed.title, event.title)
        XCTAssertEqual(parsed.notes, event.notes)
        XCTAssertEqual(parsed.location, event.location)
        XCTAssertEqual(parsed.time, event.time)
        XCTAssertEqual(parsed.recurrence, event.recurrence)
        XCTAssertEqual(parsed.attendees, event.attendees)
        XCTAssertEqual(parsed.organizerEmail, event.organizerEmail)
        XCTAssertEqual(parsed.reminders, event.reminders)
        XCTAssertEqual(parsed.meetingURL, event.meetingURL)
        XCTAssertEqual(parsed.taskID, event.taskID)
    }

    func testSerializesAllDayAsDates() throws {
        let event = CalendarEvent(
            collectionID: collection, uid: "ad-1", title: "Отпуск",
            time: .allDay(start: CalendarDay(year: 2026, month: 12, day: 29), endExclusive: CalendarDay(year: 2027, month: 1, day: 3)))
        let text = ICalendar.serialize(event)
        XCTAssertTrue(text.contains("DTSTART;VALUE=DATE:20261229"))
        XCTAssertTrue(text.contains("DTEND;VALUE=DATE:20270103"))
        XCTAssertEqual(try ICalendar.parse(text, collectionID: collection).first?.time, event.time)
    }

    func testRejectsTextWithoutCalendar() {
        XCTAssertThrowsError(try ICalendar.parse("<html>not a calendar</html>", collectionID: collection))
    }
}
