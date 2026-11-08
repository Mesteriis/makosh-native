import Foundation
import XCTest
@testable import MakoshCalendar

final class BusyEngineTests: XCTestCase {
    private let group = UUID(), account = UUID()
    private let now = Date(timeIntervalSince1970: 1_794_096_000)  // 2026-11-08 00:00Z
    private lazy var personal = CalendarCollection(accountID: account, externalID: "p", name: "Личный", groupIDs: [group])
    private lazy var workA = CalendarCollection(accountID: account, externalID: "a", name: "Работа A", groupIDs: [group])
    private lazy var workB = CalendarCollection(accountID: account, externalID: "b", name: "Работа B", groupIDs: [group])
    private lazy var feed = CalendarCollection(accountID: account, externalID: "f", name: "Подписка", access: .read, groupIDs: [group])
    private var all: [CalendarCollection] { [personal, workA, workB, feed] }
    private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }
    private func dentist(in collection: CalendarCollection, from: Double = 14, to: Double = 15) -> CalendarEvent {
        CalendarEvent(
            collectionID: collection.id, uid: UUID().uuidString, title: "Стоматолог",
            time: .timed(start: at(from), end: at(to), timeZone: nil))
    }

    func testOriginalReplicatesToEveryWritableNeighbourButNotItself() {
        let desired = BusyEngine.desired(events: [dentist(in: personal)], collections: all, now: now)
        XCTAssertEqual(Set(desired.map(\.targetCollectionID)), [workA.id, workB.id])
        XCTAssertEqual(Set(desired.map(\.time)), [.timed(start: at(14), end: at(15), timeZone: nil)])
    }

    func testBusyCopiesAreNeverSources() {
        var copy = dentist(in: workA)
        copy.busyMarker = .init(sourceEventID: UUID(), occurrenceStart: at(14))
        XCTAssertTrue(BusyEngine.desired(events: [copy], collections: all, now: now).isEmpty)
    }

    func testFreeCancelledDeclinedAndPastGiveNothing() {
        var free = dentist(in: personal)
        free.transparency = .free
        var past = dentist(in: personal, from: -3, to: -2)
        past.title = "прошло"
        var declined = dentist(in: personal)
        declined.attendees = [.init(email: "me@x.test", response: .declined, isSelf: true)]
        XCTAssertTrue(BusyEngine.desired(events: [free, past, declined], collections: all, now: now).isEmpty)
    }

    func testTwoGroupsDoNotLeakAcross() {
        let g1 = UUID(), g2 = UUID()
        let p = CalendarCollection(accountID: account, externalID: "p", name: "Личный", groupIDs: [g1, g2])
        let a = CalendarCollection(accountID: account, externalID: "a", name: "A", groupIDs: [g1])
        let b = CalendarCollection(accountID: account, externalID: "b", name: "B", groupIDs: [g2])
        XCTAssertEqual(BusyEngine.desired(events: [dentist(in: a)], collections: [p, a, b], now: now).map(\.targetCollectionID), [p.id])
        XCTAssertEqual(
            Set(BusyEngine.desired(events: [dentist(in: p)], collections: [p, a, b], now: now).map(\.targetCollectionID)), [a.id, b.id])
    }

    func testSubscriptionIsSourceNotTarget() {
        let fromFeed = BusyEngine.desired(events: [dentist(in: feed)], collections: all, now: now)
        XCTAssertEqual(Set(fromFeed.map(\.targetCollectionID)), [personal.id, workA.id, workB.id])
        let toFeed = BusyEngine.desired(events: [dentist(in: personal)], collections: all, now: now)
        XCTAssertFalse(toFeed.contains { $0.targetCollectionID == feed.id })
    }

    func testRecurringWithinHorizonOnly() {
        var daily = dentist(in: personal, from: 23.5, to: 24.5)
        daily.recurrence = CalendarRecurrence(rrule: "FREQ=DAILY")
        let desired = BusyEngine.desired(events: [daily], collections: [personal, workA], now: now)
        XCTAssertEqual(desired.count, 90)
        XCTAssertTrue(desired.allSatisfy { $0.occurrenceKey < now.addingTimeInterval(BusyEngine.horizon) })
        // An occurrence that started before now and is still running counts too.
        let running = BusyEngine.desired(events: [dentist(in: personal, from: -0.5, to: 0.5)], collections: [personal, workA], now: now)
        XCTAssertEqual(running.count, 1)
    }

    func testAllDayCopyKeepsDays() {
        let event = CalendarEvent(
            collectionID: personal.id, uid: "d", title: "Отпуск",
            time: .allDay(start: CalendarDay(year: 2026, month: 11, day: 20), endExclusive: CalendarDay(year: 2026, month: 11, day: 21)))
        let copy = BusyEngine.desired(events: [event], collections: [personal, workA], now: now).first
        guard case .allDay(let start, let end)? = copy?.time else { return XCTFail("all-day copy expected") }
        XCTAssertEqual(start, CalendarDay(year: 2026, month: 11, day: 20))
        XCTAssertEqual(end, CalendarDay(year: 2026, month: 11, day: 21))
    }

    // MARK: Reconcile

    private func desired(_ event: CalendarEvent, _ target: CalendarCollection, _ time: CalendarEventTime? = nil) -> DesiredBusyCopy {
        guard case .timed(let start, _, _) = event.time else { fatalError() }
        return DesiredBusyCopy(sourceEventID: event.id, occurrenceKey: start, targetCollectionID: target.id, time: time ?? event.time)
    }
    private func record(
        _ copy: DesiredBusyCopy, external: String, time: CalendarEventTime? = nil, state: BusyCopyState = .placed
    ) -> BusyCopyRecord {
        BusyCopyRecord(
            sourceEventID: copy.sourceEventID, occurrenceKey: copy.occurrenceKey, targetCollectionID: copy.targetCollectionID,
            externalID: external, etag: "e", time: time ?? copy.time, state: state)
    }
    private func observed(_ copy: DesiredBusyCopy, external: String, time: CalendarEventTime? = nil) -> ObservedBusyCopy {
        ObservedBusyCopy(
            externalID: external, marker: .init(sourceEventID: copy.sourceEventID, occurrenceStart: copy.occurrenceKey),
            time: time ?? copy.time, collectionID: copy.targetCollectionID)
    }

    func testReconcileCreatesMovesRemovesAndLeavesPast() {
        let event = dentist(in: personal)
        let wanted = desired(event, workA)
        XCTAssertEqual(BusyEngine.reconcile(desired: [wanted], records: [], observed: [], read: [workA.id], now: now), [.create(wanted)])

        let moved = DesiredBusyCopy(
            sourceEventID: wanted.sourceEventID, occurrenceKey: wanted.occurrenceKey, targetCollectionID: workA.id,
            time: .timed(start: at(16), end: at(17), timeZone: nil))
        let placed = record(wanted, external: "x1")
        XCTAssertEqual(
            BusyEngine.reconcile(
                desired: [moved], records: [placed], observed: [observed(wanted, external: "x1")], read: [workA.id], now: now),
            [.move(record: placed, to: moved.time)])

        XCTAssertEqual(
            BusyEngine.reconcile(desired: [], records: [placed], observed: [observed(wanted, external: "x1")], read: [workA.id], now: now),
            [.remove(placed)])

        let past = dentist(in: personal, from: -5, to: -4)
        let pastRecord = record(desired(past, workA), external: "old")
        XCTAssertEqual(BusyEngine.reconcile(desired: [], records: [pastRecord], observed: [], read: [workA.id], now: now), [])
    }

    func testReconcileRestoresTamperedCopy() {
        let wanted = desired(dentist(in: personal), workA)
        let placed = record(wanted, external: "x1")
        let shifted = observed(wanted, external: "x1", time: .timed(start: at(14.5), end: at(15.5), timeZone: nil))
        XCTAssertEqual(
            BusyEngine.reconcile(desired: [wanted], records: [placed], observed: [shifted], read: [workA.id], now: now),
            [.move(record: placed, to: wanted.time)])
        XCTAssertEqual(
            BusyEngine.reconcile(desired: [wanted], records: [placed], observed: [], read: [workA.id], now: now), [.create(wanted)])
        // A calendar not read in this pass is not judged by its absence.
        XCTAssertEqual(BusyEngine.reconcile(desired: [wanted], records: [placed], observed: [], read: [], now: now), [])
    }

    func testReconcileAdoptsCopyFoundAfterUnknown() {
        let wanted = desired(dentist(in: personal), workA)
        let found = observed(wanted, external: "late")
        XCTAssertEqual(
            BusyEngine.reconcile(desired: [wanted], records: [], observed: [found], read: [workA.id], now: now),
            [.adopt(record: wanted, observed: found)])
        let pending = record(wanted, external: "", state: .pending)
        XCTAssertEqual(
            BusyEngine.reconcile(desired: [wanted], records: [pending], observed: [found], read: [workA.id], now: now),
            [.adopt(record: wanted, observed: found)])
        XCTAssertEqual(BusyEngine.reconcile(desired: [wanted], records: [pending], observed: [], read: [workA.id], now: now), [])
    }

    func testReconcileDeletesStraysAndDuplicates() {
        let wanted = desired(dentist(in: personal), workA)
        let placed = record(wanted, external: "x1")
        let duplicate = observed(wanted, external: "x2")
        let stray = ObservedBusyCopy(
            externalID: "s1", marker: .init(sourceEventID: UUID(), occurrenceStart: at(20)),
            time: .timed(start: at(20), end: at(21), timeZone: nil), collectionID: workA.id)
        let actions = BusyEngine.reconcile(
            desired: [wanted], records: [placed], observed: [observed(wanted, external: "x1"), duplicate, stray], read: [workA.id], now: now
        )
        XCTAssertEqual(Set(actions.map { "\($0)" }), Set([BusyAction.deleteStray(duplicate), .deleteStray(stray)].map { "\($0)" }))
    }
}
