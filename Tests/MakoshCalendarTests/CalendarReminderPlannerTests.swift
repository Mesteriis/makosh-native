import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarReminderPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_096_000)
    private let collection = CalendarCollection(accountID: UUID(), externalID: "local", name: "Личный", defaultReminderMinutes: 10)

    private func event(_ fromHours: Double, reminders: [Int] = []) -> CalendarEvent {
        let start = now.addingTimeInterval(fromHours * 3600)
        return CalendarEvent(
            collectionID: collection.id, uid: UUID().uuidString, title: "Стоматолог",
            time: .timed(start: start, end: start.addingTimeInterval(3600), timeZone: nil),
            reminders: reminders)
    }

    private func snapshot(_ events: [CalendarEvent]) -> CalendarSnapshot {
        let window = DateInterval(start: now.addingTimeInterval(-86400), duration: 3 * 86400)
        return CalendarSnapshot(
            accounts: [], collections: [collection], groups: [], occurrences: CalendarExpansion.occurrences(events, in: window),
            events: Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) }), openAttempts: [], externalConflicts: [],
            staleCollectionIDs: [],
            window: window, googleAvailable: false, preferences: CalendarPreferences())
    }

    func testPlansFromEventOrCalendarDefault() {
        let own = event(2, reminders: [15]), plain = event(3)
        let planned = CalendarReminderPlanner.reminders(snapshot: snapshot([own, plain]), now: now)
        let byEvent = Dictionary(uniqueKeysWithValues: planned.map { ($0.eventID, $0) })
        XCTAssertEqual(byEvent[own.id]?.fireAt, now.addingTimeInterval(2 * 3600 - 15 * 60))
        XCTAssertEqual(byEvent[plain.id]?.fireAt, now.addingTimeInterval(3 * 3600 - 10 * 60))
        XCTAssertEqual(byEvent[plain.id]?.title, "Стоматолог")
    }

    func testSkipsCopiesDeclinedAndPast() {
        var copy = event(2)
        copy.busyMarker = .init(sourceEventID: UUID(), occurrenceStart: now)
        var declined = event(2)
        declined.attendees = [.init(email: "me@x.test", response: .declined, isSelf: true)]
        let started = event(0.1)
        let tooFar = event(30)
        XCTAssertTrue(CalendarReminderPlanner.reminders(snapshot: snapshot([copy, declined, started, tooFar]), now: now).isEmpty)
    }

    func testMovingEventChangesIdentifier() {
        var moving = event(2)
        let before = CalendarReminderPlanner.reminders(snapshot: snapshot([moving]), now: now).map(\.identifier)
        moving.time = .timed(start: now.addingTimeInterval(4 * 3600), end: now.addingTimeInterval(5 * 3600), timeZone: nil)
        let after = CalendarReminderPlanner.reminders(snapshot: snapshot([moving]), now: now).map(\.identifier)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(after.count, 1)
        XCTAssertNotEqual(before, after)
    }

    func testDeletedEventDropsReminder() {
        var gone = event(2)
        gone.deletedAt = now
        XCTAssertTrue(CalendarReminderPlanner.reminders(snapshot: snapshot([gone]), now: now).isEmpty)
    }

    func testIdentifierRoundTrip() {
        let planned = CalendarReminderPlanner.reminders(snapshot: snapshot([event(2)]), now: now).first!
        XCTAssertEqual(CalendarReminderPlanner.eventID(fromIdentifier: planned.identifier), planned.eventID)
        XCTAssertNil(CalendarReminderPlanner.eventID(fromIdentifier: "../etc"))
    }
}
