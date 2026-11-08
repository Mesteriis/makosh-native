import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarConflictsTests: XCTestCase {
    private let groupA = UUID(), groupB = UUID(), account = UUID()
    private lazy var personal = CalendarCollection(accountID: account, externalID: "p", name: "Личный", groupIDs: [groupA, groupB])
    private lazy var workA = CalendarCollection(accountID: account, externalID: "a", name: "Работа A", groupIDs: [groupA])
    private lazy var workB = CalendarCollection(accountID: account, externalID: "b", name: "Работа B", groupIDs: [groupB])
    private lazy var holidays = CalendarCollection(accountID: account, externalID: "h", name: "Праздники", access: .read)
    private var all: [CalendarCollection] { [personal, workA, workB, holidays] }
    private let day = Date(timeIntervalSince1970: 1_794_096_000)
    private func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }

    private func occurrences(_ events: [CalendarEvent]) -> ([CalendarOccurrence], [UUID: CalendarEvent]) {
        let window = DateInterval(start: day, duration: 7 * 86400)
        return (
            events.flatMap { CalendarRecurrenceExpander.occurrences(of: $0, overrides: [], in: window) },
            Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        )
    }

    func testNeighboursShareAnyGroup() {
        XCTAssertEqual(CalendarNeighbours.of(personal.id, in: all), [workA.id, workB.id])
        XCTAssertEqual(CalendarNeighbours.of(workA.id, in: all), [personal.id])
        XCTAssertEqual(CalendarNeighbours.of(holidays.id, in: all), [])
    }

    func testOverlapInNeighbourIsConflictButTouchingIsNot() {
        let call = CalendarEvent.fixture(start: 10, end: 11, collectionID: workA.id, day: day)
        let (occ, events) = occurrences([call])
        XCTAssertTrue(
            CalendarConflictFinder.conflicts(
                start: at(11), end: at(12), collectionID: personal.id, excluding: nil, occurrences: occ, events: events, collections: all
            ).isEmpty)
        let found = CalendarConflictFinder.conflicts(
            start: at(10.5), end: at(11.5), collectionID: personal.id, excluding: nil, occurrences: occ, events: events, collections: all)
        XCTAssertEqual(found.map(\.eventID), [call.id])
        // Work B does not share a group with work A.
        XCTAssertTrue(
            CalendarConflictFinder.conflicts(
                start: at(10.5), end: at(11.5), collectionID: workB.id, excluding: nil, occurrences: occ, events: events, collections: all
            ).isEmpty)
    }

    func testOwnCalendarAndExcludedEvent() {
        let call = CalendarEvent.fixture(start: 10, end: 11, collectionID: personal.id, day: day)
        let (occ, events) = occurrences([call])
        XCTAssertEqual(
            CalendarConflictFinder.conflicts(
                start: at(10), end: at(11), collectionID: personal.id, excluding: nil, occurrences: occ, events: events, collections: all
            ).count, 1)
        XCTAssertTrue(
            CalendarConflictFinder.conflicts(
                start: at(10), end: at(11), collectionID: personal.id, excluding: call.id, occurrences: occ, events: events,
                collections: all
            ).isEmpty)
    }

    func testFreeAndDeclinedDoNotConflictButBusyCopiesDo() {
        var free = CalendarEvent.fixture(start: 10, end: 11, collectionID: workA.id, day: day)
        free.transparency = .free
        var declined = CalendarEvent.fixture(start: 10, end: 11, collectionID: workA.id, day: day)
        declined.attendees = [.init(email: "me@x.test", response: .declined, isSelf: true)]
        var copy = CalendarEvent.fixture(start: 14, end: 15, collectionID: workA.id, day: day)
        copy.busyMarker = .init(sourceEventID: UUID(), occurrenceStart: at(14))
        let (occ, events) = occurrences([free, declined, copy])
        XCTAssertTrue(
            CalendarConflictFinder.conflicts(
                start: at(10), end: at(11), collectionID: personal.id, excluding: nil, occurrences: occ, events: events, collections: all
            ).isEmpty)
        let found = CalendarConflictFinder.conflicts(
            start: at(14), end: at(15), collectionID: personal.id, excluding: nil, occurrences: occ, events: events, collections: all)
        XCTAssertEqual(found.map(\.isBusyCopy), [true])
    }

    func testConflictMarksInvitation() {
        var invite = CalendarEvent.fixture(start: 10, end: 11, collectionID: workA.id, day: day)
        invite.organizerEmail = "boss@x.test"
        invite.attendees = [
            .init(email: "boss@x.test", isOrganizer: true), .init(email: "me@x.test", response: .needsAction, isSelf: true),
        ]
        let (occ, events) = occurrences([invite])
        let found = CalendarConflictFinder.conflicts(
            start: at(10), end: at(11), collectionID: personal.id, excluding: nil, occurrences: occ, events: events, collections: all)
        XCTAssertEqual(found.first?.isInvitation, true)
    }

    func testNearestFreeSkipsBusy() {
        let one = CalendarEvent.fixture(start: 10, end: 12, collectionID: workA.id, day: day)
        var two = CalendarEvent.fixture(start: 12, end: 13, collectionID: personal.id, day: day)
        two.time = .timed(start: at(12.25), end: at(13), timeZone: nil)
        let (occ, events) = occurrences([one, two])
        XCTAssertEqual(
            CalendarConflictFinder.nearestFree(
                length: 3600, after: at(10), collectionID: personal.id, occurrences: occ, events: events, collections: all), at(13))
        XCTAssertEqual(
            CalendarConflictFinder.nearestFree(
                length: 900, after: at(10), collectionID: personal.id, occurrences: occ, events: events, collections: all), at(12))
    }
}
