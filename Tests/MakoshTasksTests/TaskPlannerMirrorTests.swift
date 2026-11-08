import Foundation
import MakoshCore
import XCTest
@testable import MakoshTasks

/// Records what the planner hands to the calendar and supplies external busy blocks.
final class FakePlannerMirror: TaskPlannerMirror, @unchecked Sendable {
    let lock = NSLock()
    var blocks: [(start: Int, end: Int, title: String)] = []
    var changes: [[TaskPlanSlot]] = []
    var lastTitles: [UUID: String] = [:]

    func externalBlocks(day: Date, planID: UUID, calendar: Calendar) async -> [TaskPlanSlot] {
        lock.withLock {
            blocks.map {
                TaskPlanSlot(planID: planID, title: $0.title, start: $0.start, end: $0.end, kind: .blocked, external: true)
            }
        }
    }
    func slotsChanged(day: Date, slots: [TaskPlanSlot], titles: [UUID: String], calendar: Calendar) async {
        lock.withLock {
            changes.append(slots)
            lastTitles = titles
        }
    }
}

@MainActor final class TaskPlannerMirrorTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }

    private func model(_ mirror: FakePlannerMirror) async throws -> (TasksWorkspaceModel, TaskStore) {
        let db = try tasksDatabase()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = TaskStore(connectionString: db.connectionString, schema: db.schema, now: { now })
        let service = TasksService(store: store, vault: JiraTokenVault(access: .memory()), now: { now }) { _, _ in FakeJiraAdapter() }
        try await service.open()
        let model = TasksWorkspaceModel(service: service, calendar: calendar, now: { now })
        model.plannerMirror = mirror
        await model.refresh()
        return (model, store)
    }

    func testExternalBlocksJoinPlannerAndDropsAvoidThem() async throws {
        let mirror = FakePlannerMirror()
        mirror.blocks = [(10 * 60, 11 * 60, "Созвон A")]
        let (model, store) = try await model(mirror)
        let task = try await store.insert(Task(title: "Отчёт", estimateMinutes: 60), actor: .user)
        await model.refresh()
        await model.loadPlanner()
        XCTAssertEqual(model.slots.filter(\.isExternal).map(\.title), ["Созвон A"])
        await model.dropTasks([task.id], at: 10 * 60)
        let own = model.slots.filter { !$0.isExternal }
        XCTAssertEqual(own.map(\.start), [11 * 60], "the drop moves past the calendar's busy time")
        XCTAssertEqual(mirror.changes.last?.map(\.taskID), [task.id], "only own slots reach the calendar")
        XCTAssertEqual(mirror.lastTitles[task.id], "Отчёт")
    }

    func testExternalBlocksCannotBeMovedOrRemoved() async throws {
        let mirror = FakePlannerMirror()
        mirror.blocks = [(12 * 60, 13 * 60, "Занято")]
        let (model, _) = try await model(mirror)
        await model.loadPlanner()
        let external = try XCTUnwrap(model.slots.first(where: \.isExternal))
        await model.moveSlot(id: external.id, to: 14 * 60)
        await model.removeSlot(id: external.id)
        await model.resizeSlot(id: external.id, end: 15 * 60)
        XCTAssertEqual(model.slots.first(where: \.isExternal)?.start, 12 * 60)
        XCTAssertTrue(mirror.changes.isEmpty, "nothing was changed, nothing mirrored")
    }

    func testSlotCalendarChoiceIsKept() async throws {
        let mirror = FakePlannerMirror()
        let (model, store) = try await model(mirror)
        let task = try await store.insert(Task(title: "Ревью"), actor: .user)
        await model.refresh()
        await model.loadPlanner()
        await model.dropTasks([task.id], at: 9 * 60)
        let slot = try XCTUnwrap(model.slots.first { $0.taskID == task.id })
        let calendarID = UUID()
        await model.setSlotCalendar(id: slot.id, calendarID: calendarID)
        let stored = try await store.slot(id: slot.id)
        XCTAssertEqual(stored?.calendarID, calendarID)
        XCTAssertEqual(mirror.changes.last?.first?.calendarID, calendarID)
    }

    func testOlderSlotRowsReadWithoutNewFields() throws {
        let json =
            #"{"id":"6A7E4C2B-0000-4000-8000-000000000001","planID":"6A7E4C2B-0000-4000-8000-000000000002","start":540,"end":600,"kind":"task"}"#
        let slot = try JSONDecoder().decode(TaskPlanSlot.self, from: Data(json.utf8))
        XCTAssertNil(slot.calendarID)
        XCTAssertFalse(slot.isExternal)
    }
}
