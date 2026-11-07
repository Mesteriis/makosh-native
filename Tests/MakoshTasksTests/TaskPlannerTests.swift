import Foundation
import XCTest
@testable import MakoshTasks

final class TaskPlannerTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }
    private let dayStart = 9 * 60, dayEnd = 17 * 60

    func testTimeStringsRoundTrip() {
        XCTAssertEqual(TaskPlanSlot.time(9 * 60 + 5), "09:05")
        XCTAssertEqual(TaskPlanSlot.minutes("17:30"), 17 * 60 + 30)
        XCTAssertNil(TaskPlanSlot.minutes("25:00"))
        XCTAssertNil(TaskPlanSlot.minutes("9"))
        XCTAssertEqual(TaskPlannerRules.snap(9 * 60 + 14, step: 30), 9 * 60)
        XCTAssertEqual(TaskPlannerRules.snap(9 * 60 + 16, step: 30), 9 * 60 + 30)
    }

    func testEstimateMinutesDefaultsAndFloors() {
        XCTAssertEqual(TaskPlannerRules.estimateMinutes(Task(title: "a")), 60)
        XCTAssertEqual(TaskPlannerRules.estimateMinutes(Task(title: "a", estimateMinutes: 5)), 15)
        XCTAssertEqual(TaskPlannerRules.estimateMinutes(Task(title: "a", estimateMinutes: 90)), 90)
    }

    func testFreeStartPushesPastOccupiedThenBeforeIt() {
        let occupied = [(10 * 60)...(11 * 60)]
        XCTAssertEqual(
            TaskPlannerRules.freeStart(10 * 60 + 30, duration: 60, occupied: occupied, dayStart: dayStart, dayEnd: dayEnd, step: 30),
            11 * 60)
        XCTAssertEqual(
            TaskPlannerRules.freeStart(9 * 60, duration: 60, occupied: occupied, dayStart: dayStart, dayEnd: dayEnd, step: 30), 9 * 60)
        // Pushed past the end of the day → placed before the obstacle instead.
        let late = [(16 * 60)...(17 * 60)]
        XCTAssertEqual(
            TaskPlannerRules.freeStart(16 * 60 + 30, duration: 60, occupied: late, dayStart: dayStart, dayEnd: dayEnd, step: 30), 15 * 60)
        XCTAssertNil(
            TaskPlannerRules.freeStart(9 * 60, duration: 9 * 60, occupied: [], dayStart: dayStart, dayEnd: dayEnd, step: 30),
            "longer than the day")
    }

    func testPlacementsFitGapAndWriteEstimate() {
        let a = UUID(), b = UUID()
        let occupied = [(10 * 60 + 30)...(11 * 60)]
        let placements = TaskPlannerRules.placements(
            taskIDs: [a, b], estimates: [a: nil, b: 30], at: 10 * 60, occupied: occupied, dayStart: dayStart, dayEnd: dayEnd, step: 30)
        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(placements[0].taskID, a)
        XCTAssertEqual(placements[0].start, 10 * 60)
        XCTAssertEqual(placements[0].end, 10 * 60 + 30, "a task without an estimate takes the gap before the slot")
        XCTAssertEqual(placements[0].fittedEstimate, 30)
        XCTAssertEqual(placements[1].taskID, b)
        XCTAssertEqual(placements[1].start, 11 * 60, "the next task continues after the obstacle")
        XCTAssertEqual(placements[1].end, 11 * 60 + 30)
        XCTAssertNil(placements[1].fittedEstimate)
    }

    func testDropNearDayEndPlacesWhatFitsAndStops() {
        let a = UUID(), b = UUID()
        let placements = TaskPlannerRules.placements(
            taskIDs: [a, b], estimates: [a: 60, b: 60], at: 16 * 60 + 30, occupied: [], dayStart: dayStart, dayEnd: dayEnd, step: 30)
        XCTAssertEqual(placements.map(\.taskID), [a])
        XCTAssertEqual(placements[0].start, 16 * 60)
        XCTAssertEqual(placements[0].end, 17 * 60)
        XCTAssertTrue(placements.allSatisfy { $0.end <= dayEnd })
    }

    func testBlockedDurationStopsAtNextSlot() {
        XCTAssertEqual(TaskPlannerRules.blockedDuration(at: 12 * 60, occupied: [(12 * 60 + 30)...(13 * 60)], dayEnd: dayEnd), 30)
        XCTAssertEqual(TaskPlannerRules.blockedDuration(at: 12 * 60, occupied: [], dayEnd: dayEnd), 60)
        XCTAssertEqual(TaskPlannerRules.blockedDuration(at: 16 * 60 + 45, occupied: [], dayEnd: dayEnd), 15)
        XCTAssertEqual(TaskPlannerRules.blockedDuration(at: 12 * 60, occupied: [(11 * 60)...(13 * 60)], dayEnd: dayEnd), 0)
    }

    func testWeekDaysRunMondayToSunday() {
        let week = TaskPlannerRules.weekDays(containing: day(2026, 11, 7), calendar: calendar)  // Saturday
        XCTAssertEqual(week.first, day(2026, 11, 2))
        XCTAssertEqual(week.last, day(2026, 11, 8))
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(
            TaskPlannerRules.weekDays(containing: day(2026, 11, 8), calendar: calendar).first, day(2026, 11, 2),
            "Sunday belongs to the week before")
    }

    func testWeeklyBlockedSlotRecursOnSameWeekday() {
        let slot = TaskPlanSlot(planID: UUID(), title: "Обед", start: 12 * 60, end: 13 * 60, kind: .blocked, recurrence: .weekly)
        XCTAssertTrue(TaskPlannerRules.recurs(slot, from: day(2026, 11, 2), on: day(2026, 11, 9), calendar: calendar))
        XCTAssertFalse(TaskPlannerRules.recurs(slot, from: day(2026, 11, 2), on: day(2026, 11, 10), calendar: calendar))
        var daily = slot
        daily.recurrence = .daily
        XCTAssertTrue(TaskPlannerRules.recurs(daily, from: day(2026, 11, 2), on: day(2026, 11, 10), calendar: calendar))
        var none = slot
        none.recurrence = nil
        XCTAssertFalse(TaskPlannerRules.recurs(none, from: day(2026, 11, 2), on: day(2026, 11, 9), calendar: calendar))
        var task = slot
        task.kind = .task
        XCTAssertFalse(
            TaskPlannerRules.recurs(task, from: day(2026, 11, 2), on: day(2026, 11, 9), calendar: calendar), "task slots never recur")
    }

    func testBiweeklyRecursEveryOtherWeek() {
        let slot = TaskPlanSlot(planID: UUID(), title: "Планёрка", start: 10 * 60, end: 11 * 60, kind: .blocked, recurrence: .biweekly)
        XCTAssertFalse(TaskPlannerRules.recurs(slot, from: day(2026, 11, 2), on: day(2026, 11, 9), calendar: calendar))
        XCTAssertTrue(TaskPlannerRules.recurs(slot, from: day(2026, 11, 2), on: day(2026, 11, 16), calendar: calendar))
        XCTAssertTrue(TaskPlannerRules.recurs(slot, from: day(2026, 11, 16), on: day(2026, 11, 2), calendar: calendar), "earlier weeks too")
    }

    func testSummaryExcludesBlockedFromAvailable() {
        let plan = UUID()
        let slots = [
            TaskPlanSlot(planID: plan, taskID: UUID(), start: 9 * 60, end: 10 * 60 + 30, kind: .task),
            TaskPlanSlot(planID: plan, title: "Обед", start: 12 * 60, end: 13 * 60, kind: .blocked),
        ]
        let summary = TaskPlannerRules.summary(slots: slots, dayStart: 9, dayEnd: 17)
        XCTAssertEqual(summary.plannedMinutes, 90)
        XCTAssertEqual(summary.availableMinutes, 7 * 60)
    }

    func testEffectiveSlotsDropDeletedTasksAndDedupe() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let today = day(2026, 11, 9), lastWeek = day(2026, 11, 2)
        let plan = try await store.plan(for: today, defaults: (9, 17), calendar: calendar)
        let earlier = try await store.plan(for: lastWeek, defaults: (9, 17), calendar: calendar)
        let task = try await store.insert(Task(title: "a"), actor: .user)
        let gone = try await store.insert(Task(title: "b"), actor: .user)
        try await store.insertSlot(TaskPlanSlot(planID: plan.id, taskID: task.id, start: 9 * 60, end: 10 * 60, kind: .task))
        try await store.insertSlot(TaskPlanSlot(planID: plan.id, taskID: gone.id, start: 10 * 60, end: 11 * 60, kind: .task))
        try await store.insertSlot(TaskPlanSlot(planID: plan.id, title: "Обед", start: 12 * 60, end: 13 * 60, kind: .blocked))
        try await store.insertSlot(
            TaskPlanSlot(planID: earlier.id, title: "Обед", start: 12 * 60, end: 13 * 60, kind: .blocked, recurrence: .weekly))
        let recurring = TaskPlanSlot(
            planID: earlier.id, title: "Планёрка", start: 15 * 60, end: 16 * 60, kind: .blocked, recurrence: .weekly)
        try await store.insertSlot(recurring)
        try await store.softDelete(id: gone.id, expectedRevision: 1, actor: .user)
        let slots = try await store.effectiveSlots(for: today, planID: plan.id, calendar: calendar)
        XCTAssertEqual(
            slots.map(\.start), [9 * 60, 12 * 60, 15 * 60], "deleted task's slot dropped, duplicate lunch skipped, recurring added")
        XCTAssertEqual(slots.last?.id, recurring.id, "a recurring slot keeps its original id")
        let planned = try await store.plannedTaskIDs()
        XCTAssertEqual(planned, [task.id])
        let stale = try await store.slots(for: today, calendar: calendar)
        XCTAssertEqual(stale.count, 3)
        let none = try await store.slots(for: day(2026, 12, 7), calendar: calendar)  // a Monday
        XCTAssertEqual(none.map(\.title), ["Обед", "Планёрка"], "a day without its own plan still shows the recurring blocks")
    }

    func testSlotsRoundTripWithTimeStrings() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let plan = try await store.plan(for: day(2026, 11, 9), defaults: (8, 18), calendar: calendar)
        XCTAssertEqual(plan.dayStart, 8)
        let again = try await store.plan(for: day(2026, 11, 9), defaults: (9, 17), calendar: calendar)
        XCTAssertEqual(again.id, plan.id)
        XCTAssertEqual(again.dayStart, 9, "the settings' hours win over the stored plan")
        var slot = TaskPlanSlot(planID: plan.id, title: "Обед", start: 12 * 60 + 30, end: 13 * 60, kind: .blocked)
        try await store.insertSlot(slot)
        let rows = try db.execute("SELECT start_time, end_time FROM \"\(db.schema)\".tasks_day_plan_slots")
        XCTAssertEqual(rows.first, ["12:30", "13:00"])
        slot.start = 13 * 60
        slot.end = 13 * 60 + 30
        slot.title = "Поздний обед"
        try await store.updateSlot(slot)
        let read = try await store.effectiveSlots(for: day(2026, 11, 9), planID: plan.id, calendar: calendar)
        XCTAssertEqual(read, [slot])
        try await store.removeSlot(id: slot.id)
        let empty = try await store.effectiveSlots(for: day(2026, 11, 9), planID: plan.id, calendar: calendar)
        XCTAssertTrue(empty.isEmpty)
    }
}
