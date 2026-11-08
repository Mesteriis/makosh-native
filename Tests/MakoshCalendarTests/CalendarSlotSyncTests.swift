import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarSlotSyncTests: XCTestCase {
    private func day(_ h: CalendarServiceHarness) -> DateInterval { DateInterval(start: h.at(0), duration: 86400) }

    func testSlotsBecomeEventsIdempotently() async throws {
        let w = try await busyWorld()
        let slot = CalendarSlotValue(
            id: UUID(), taskID: UUID(), title: "Отчёт", start: w.h.at(10), end: w.h.at(11), rrule: nil, collectionID: nil)
        try await w.h.service.syncSlots(day: day(w.h), slots: [slot], defaultCollectionID: w.personal.id)
        try await w.h.service.syncSlots(day: day(w.h), slots: [slot], defaultCollectionID: w.personal.id)
        let events = try await w.h.store.liveEvents(collectionID: w.personal.id).filter { $0.uid == CalendarSlotValue.uid(slot.id) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.taskID, slot.taskID)
        XCTAssertEqual(events.first?.title, "Отчёт")
        let copies = await w.copies(w.a, "work-a")
        XCTAssertEqual(copies.count, 1, "a planned slot spreads busy time like any event")
    }

    func testMovedSlotMovesEventAndChosenCalendarIsUsed() async throws {
        let w = try await busyWorld()
        var slot = CalendarSlotValue(
            id: UUID(), taskID: nil, title: "Обед", start: w.h.at(12), end: w.h.at(13), rrule: nil, collectionID: w.workA.id)
        try await w.h.service.syncSlots(day: day(w.h), slots: [slot], defaultCollectionID: w.personal.id)
        let inA = await w.a.externalEvents(collectionExternalID: "work-a").filter { $0.uid == CalendarSlotValue.uid(slot.id) }
        XCTAssertEqual(inA.count, 1)
        slot.start = w.h.at(13)
        slot.end = w.h.at(14)
        try await w.h.service.syncSlots(day: day(w.h), slots: [slot], defaultCollectionID: w.personal.id)
        let moved = await w.a.externalEvents(collectionExternalID: "work-a").first { $0.uid == CalendarSlotValue.uid(slot.id) }
        XCTAssertEqual(moved?.time, .timed(start: w.h.at(13), end: w.h.at(14), timeZone: nil))
    }

    func testRemovedSlotDeletesEvent() async throws {
        let w = try await busyWorld()
        let slot = CalendarSlotValue(
            id: UUID(), taskID: nil, title: "Звонок", start: w.h.at(9), end: w.h.at(10), rrule: nil, collectionID: nil)
        try await w.h.service.syncSlots(day: day(w.h), slots: [slot], defaultCollectionID: w.personal.id)
        try await w.h.service.syncSlots(day: day(w.h), slots: [], defaultCollectionID: w.personal.id)
        let left = try await w.h.store.liveEvents(collectionID: w.personal.id).filter { $0.uid.hasPrefix("makosh-slot-") }
        XCTAssertTrue(left.isEmpty)
        let copies = await w.copies(w.a, "work-a")
        XCTAssertTrue(copies.isEmpty)
    }

    func testRecurringSlotBecomesRRuleOnce() async throws {
        let w = try await busyWorld()
        let slot = CalendarSlotValue(
            id: UUID(), taskID: nil, title: "Обед", start: w.h.at(12.5), end: w.h.at(13), rrule: "FREQ=DAILY", collectionID: nil)
        try await w.h.service.syncSlots(day: day(w.h), slots: [slot], defaultCollectionID: w.personal.id)
        var next = slot
        next.start = w.h.at(36.5)
        next.end = w.h.at(37)
        try await w.h.service.syncSlots(
            day: DateInterval(start: w.h.at(24), duration: 86400), slots: [next], defaultCollectionID: w.personal.id)
        let series = try await w.h.store.liveEvents(collectionID: w.personal.id).filter { $0.uid == CalendarSlotValue.uid(slot.id) }
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.recurrence?.rrule, "FREQ=DAILY")
        XCTAssertEqual(series.first?.time, .timed(start: w.h.at(12.5), end: w.h.at(13), timeZone: nil), "the series keeps its first day")
    }

    func testExternalBusyExcludesSlotEvents() async throws {
        let w = try await busyWorld(aEvents: [timed("Созвон A", 15, 16)])
        let slot = CalendarSlotValue(
            id: UUID(), taskID: nil, title: "Отчёт", start: w.h.at(10), end: w.h.at(11), rrule: nil, collectionID: nil)
        try await w.h.service.syncSlots(day: day(w.h), slots: [slot], defaultCollectionID: w.personal.id)
        let busy = try await w.h.service.busyBlocks(day: day(w.h))
        XCTAssertEqual(busy.map(\.title), ["Созвон A"])
        XCTAssertEqual(busy.first?.start, w.h.at(15))
    }
}
