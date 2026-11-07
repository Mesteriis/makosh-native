import Foundation
import MakoshCore
import XCTest
@testable import MakoshTasks

final class TaskClosingTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }

    private func close(_ store: TaskStore, _ task: Task, actor: TaskActor = .user) async throws -> TaskWriteResult {
        var value = task
        value.status = .done
        value.completedAt = Date()
        return try await store.apply(value, expectedRevision: task.revision, actor: actor)
    }
    private func reopen(_ store: TaskStore, _ task: Task) async throws -> TaskWriteResult {
        var value = task
        value.status = .inbox
        value.completedAt = nil
        return try await store.apply(value, expectedRevision: task.revision, actor: .user)
    }

    func testClosingSpawnsNextOccurrenceOnce() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let today = calendar.startOfDay(for: Date())
        let task = try await store.insert(
            Task(
                title: "Разобрать почту", priority: 2, list: "Рутина", tags: ["почта"], personas: ["Боб"], due: today, postponed: 3,
                dependsOn: [UUID()], recurrence: "daily", flowID: "Неделя"), actor: .user)
        let result = try await close(store, task)
        let spawned = try XCTUnwrap(result.effects.spawned)
        XCTAssertEqual(spawned.id, TaskRecurrence.spawnID(for: task.id))
        XCTAssertEqual(spawned.due, calendar.date(byAdding: .day, value: 1, to: today))
        XCTAssertEqual(spawned.status, .active)
        XCTAssertEqual(spawned.title, task.title)
        XCTAssertEqual(spawned.priority, 2)
        XCTAssertEqual(spawned.list, "Рутина")
        XCTAssertEqual(spawned.tags, ["почта"])
        XCTAssertEqual(spawned.personas, ["Боб"])
        XCTAssertEqual(spawned.recurrence, "daily")
        XCTAssertEqual(spawned.flowID, "Неделя")
        XCTAssertEqual(spawned.dependsOn, [])
        XCTAssertEqual(spawned.postponed, 0)
        XCTAssertNil(spawned.source)
        XCTAssertNotEqual(spawned.code, task.code)
        XCTAssertFalse(result.effects.resurrected)
        let spawnVersions = try await store.versions(taskID: spawned.id)
        XCTAssertEqual(spawnVersions.map(\.changedFields), [["spawn-of:" + task.code]])
        // A repeated done on the closed task changes nothing.
        let again = try await store.apply(result.task, expectedRevision: result.task.revision, actor: .user)
        XCTAssertNil(again.effects.spawned)
        let live = try await store.tasks().filter { $0.id == spawned.id }
        XCTAssertEqual(live.count, 1)
    }

    func testReopenAndCloseAgainResurrectsTheSpawn() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let task = try await store.insert(Task(title: "Отчёт", recurrence: "weekly"), actor: .user)
        let closed = try await close(store, task)
        let spawn = try XCTUnwrap(closed.effects.spawned)
        let reopened = try await reopen(store, closed.task)
        XCTAssertEqual(reopened.effects.removedSpawn, spawn.id)
        let removed = try await store.task(id: spawn.id)
        XCTAssertNotNil(removed?.deletedAt)
        let closedAgain = try await close(store, reopened.task)
        XCTAssertTrue(closedAgain.effects.resurrected)
        XCTAssertEqual(closedAgain.effects.spawned?.id, spawn.id)
        let live = try await store.tasks().filter { $0.recurrence == "weekly" && $0.id != task.id }
        XCTAssertEqual(live.map(\.id), [spawn.id])
        XCTAssertNil(live.first?.deletedAt)
    }

    func testEditedSpawnSurvivesReopen() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let task = try await store.insert(Task(title: "Отчёт", recurrence: "weekly"), actor: .user)
        let closed = try await close(store, task)
        var spawn = try XCTUnwrap(closed.effects.spawned)
        spawn.title = "Отчёт (правлен)"
        _ = try await store.update(spawn, expectedRevision: spawn.revision, actor: .user)
        let reopened = try await reopen(store, closed.task)
        XCTAssertNil(reopened.effects.removedSpawn)
        let kept = try await store.task(id: spawn.id)
        XCTAssertNil(kept?.deletedAt)
    }

    func testClosingByProviderActivatesDependents() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let blocker = try await store.insert(Task(title: "Блокер"), actor: .user)
        let dependent = try await store.insert(Task(title: "Зависимая", dependsOn: [blocker.id]), actor: .user)
        let other = try await store.insert(Task(title: "Другая", status: .active), actor: .user)
        let result = try await close(store, blocker, actor: .provider)
        XCTAssertEqual(result.effects.activated, [dependent.id])
        let activated = try await store.task(id: dependent.id)
        XCTAssertEqual(activated?.status, .active)
        let versions = try await store.versions(taskID: dependent.id)
        XCTAssertEqual(versions.last?.actor, .provider)
        XCTAssertEqual(versions.last?.changedFields, ["status", "activated-after:" + blocker.code])
        let untouched = try await store.task(id: other.id)
        XCTAssertEqual(untouched?.revision, 1)
    }

    func testReopeningRevertsActivatedDependents() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let blocker = try await store.insert(Task(title: "Блокер", status: .active), actor: .user)
        let dependent = try await store.insert(Task(title: "Зависимая", dependsOn: [blocker.id]), actor: .user)
        let manual = try await store.insert(Task(title: "Вручную", status: .active, dependsOn: [blocker.id]), actor: .user)
        let closed = try await close(store, blocker)
        XCTAssertEqual(closed.effects.activated, [dependent.id])
        let activatedFound = try await store.task(id: dependent.id)
        let activatedRevision = try XCTUnwrap(activatedFound).revision
        let reopened = try await reopen(store, closed.task)
        XCTAssertEqual(reopened.effects.deactivated, [dependent.id])
        let touchedFound = try await store.task(id: dependent.id)
        let touched = try XCTUnwrap(touchedFound)
        XCTAssertEqual(touched.status, .inbox)
        XCTAssertEqual(touched.revision, activatedRevision + 1)
        let untouched = try await store.task(id: manual.id)
        XCTAssertEqual(untouched?.status, .active, "a task the user activated by hand is not touched")
        let versions = try await store.versions(taskID: dependent.id)
        XCTAssertEqual(versions.last?.changedFields, ["status", "deactivated-after:" + blocker.code])
    }

    func testUpdateKeepsItsSignatureAndRunsTheRules() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let task = try await store.insert(Task(title: "Отчёт", recurrence: "monthly"), actor: .user)
        var value = task
        value.status = .done
        _ = try await store.update(value, expectedRevision: task.revision, actor: .user)
        let spawn = try await store.task(id: TaskRecurrence.spawnID(for: task.id))
        XCTAssertEqual(spawn?.status, .active)
    }
}
