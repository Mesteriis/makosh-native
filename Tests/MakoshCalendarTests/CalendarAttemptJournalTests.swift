import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarAttemptJournalTests: XCTestCase {
    func testLifecycleAndForbiddenTransitions() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let event = UUID(), collection = UUID()
        let attempt = try await store.beginAttempt(
            kind: .createEvent, eventID: event, copyID: nil, collectionID: collection, payload: Data())
        XCTAssertEqual(attempt.state, .queued)
        try await store.markSent(attempt.id)
        try await store.settle(attempt.id, state: .confirmed, failure: nil)
        do {
            try await store.settle(attempt.id, state: .unknown, failure: nil)
            XCTFail("a settled attempt must not reopen")
        } catch let failure as CalendarFailure { XCTAssertEqual(failure, .invalidInput("attempt transition")) }
        let second = try await store.beginAttempt(
            kind: .updateEvent, eventID: event, copyID: nil, collectionID: collection, payload: Data())
        try await store.markSent(second.id)
        try await store.settle(second.id, state: .unknown, failure: .unknownOutcome(stage: "write"))
        try await store.settle(second.id, state: .rejected, failure: .rejected(code: 404, stage: "check"))
        let history = try await store.attempts(eventID: event)
        XCTAssertEqual(history.map(\.state), [.confirmed, .rejected])
        XCTAssertNotNil(history.last?.resolvedAt)
        XCTAssertEqual(history.last?.failure, .rejected(code: 404, stage: "check"))
    }

    func testOneOpenAttemptPerKindEventAndCalendar() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let event = UUID(), collection = UUID()
        _ = try await store.beginAttempt(kind: .createEvent, eventID: event, copyID: nil, collectionID: collection, payload: Data())
        do {
            _ = try await store.beginAttempt(kind: .createEvent, eventID: event, copyID: nil, collectionID: collection, payload: Data())
            XCTFail("second open attempt must be refused")
        } catch let failure as CalendarFailure { XCTAssertEqual(failure, .invalidInput("attempt open")) }
        // Another calendar or another kind is a different attempt.
        _ = try await store.beginAttempt(kind: .createEvent, eventID: event, copyID: nil, collectionID: UUID(), payload: Data())
        _ = try await store.beginAttempt(kind: .respond, eventID: event, copyID: nil, collectionID: collection, payload: Data())
        let copy = UUID()
        _ = try await store.beginAttempt(kind: .createCopy, eventID: nil, copyID: copy, collectionID: collection, payload: Data())
        do {
            _ = try await store.beginAttempt(kind: .createCopy, eventID: nil, copyID: copy, collectionID: collection, payload: Data())
            XCTFail("second open copy attempt must be refused")
        } catch let failure as CalendarFailure { XCTAssertEqual(failure, .invalidInput("attempt open")) }
        let open = try await store.openAttempts()
        XCTAssertEqual(open.count, 4)
    }

    func testSentBecomesUnknownAfterReopen() async throws {
        let db = try calendarDatabase()
        let store = try await calendarStore(db)
        let attempt = try await store.beginAttempt(
            kind: .createEvent, eventID: UUID(), copyID: nil, collectionID: UUID(), payload: Data("p".utf8))
        try await store.markSent(attempt.id)
        await store.close()
        let reopened = try await calendarStore(db)
        let open = try await reopened.openAttempts()
        XCTAssertEqual(open.map(\.state), [.unknown])
        XCTAssertEqual(open.first?.failure, .unknownOutcome(stage: "restart"))
        XCTAssertEqual(open.first?.payload, Data("p".utf8))
    }

    func testBusyCopyUniquePerSourceOccurrenceTarget() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let source = UUID(), target = UUID(), key = Date(timeIntervalSince1970: 1_794_150_000)
        let time = CalendarEventTime.timed(start: key, end: key.addingTimeInterval(3600), timeZone: nil)
        let record = BusyCopyRecord(sourceEventID: source, occurrenceKey: key, targetCollectionID: target, time: time, state: .pending)
        try await store.saveBusyCopy(record)
        var placed = record
        placed.state = .placed
        placed.externalID = "x1"
        try await store.saveBusyCopy(placed)
        let duplicate = BusyCopyRecord(sourceEventID: source, occurrenceKey: key, targetCollectionID: target, time: time, state: .pending)
        do {
            try await store.saveBusyCopy(duplicate)
            XCTFail("a second record for the same copy must be refused")
        } catch is CalendarFailure {}
        let stored = try await store.busyCopies(targetCollectionID: target)
        XCTAssertEqual(stored, [placed])
        let all = try await store.busyCopies(targetCollectionID: nil)
        XCTAssertEqual(all.count, 1)
        try await store.removeBusyCopy(id: record.id)
        let none = try await store.busyCopies(targetCollectionID: nil)
        XCTAssertTrue(none.isEmpty)
    }
}
