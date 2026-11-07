import Foundation
import MakoshCore
import MakoshJira
import XCTest
@testable import MakoshTasks

@MainActor final class TasksWorkspaceModelTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }

    private struct Harness {
        let db: TasksTestDatabase
        let store: TaskStore
        let adapter: FakeJiraAdapter
        let service: TasksService
        let model: TasksWorkspaceModel
        let clock: Clock
        let connection: JiraConnection
    }

    private func harness(connected: Bool = true) async throws -> Harness {
        let db = try tasksDatabase()
        let clock = Clock()
        let adapter = FakeJiraAdapter()
        adapter.statusesByProject["QA"] = [FakeJiraAdapter.toDo, FakeJiraAdapter.inProgress, FakeJiraAdapter.done]
        let store = TaskStore(connectionString: db.connectionString, schema: db.schema, now: { clock.now() })
        let service = TasksService(store: store, vault: JiraTokenVault(access: .memory()), now: { clock.now() }) { _, _ in adapter }
        try await service.open()
        let connection = JiraConnection(
            name: "Работа", origin: URL(string: "https://jira.test")!, email: "me@example.com", pollInterval: 60)
        if connected { try await service.save(connection, token: "t") }
        let model = TasksWorkspaceModel(service: service, calendar: calendar, now: { clock.now() })
        await model.refresh()
        return Harness(db: db, store: store, adapter: adapter, service: service, model: model, clock: clock, connection: connection)
    }

    func testMineHidesNoneMembershipAndDeleted() async throws {
        let h = try await harness()
        let local = try await h.store.insert(Task(title: "Локальная"), actor: .user)
        let gone = try await h.store.insert(
            Task(
                title: "Ушла",
                source: TaskSource(
                    identity: ServiceIdentity(service: "jira", accountID: h.connection.id.uuidString, externalID: "9"), membership: .none)),
            actor: .provider)
        let kept = try await h.store.insert(
            Task(
                title: "Оставлена",
                source: TaskSource(
                    identity: ServiceIdentity(service: "jira", accountID: h.connection.id.uuidString, externalID: "8"), membership: .kept)),
            actor: .provider)
        let deleted = try await h.store.insert(Task(title: "Удалена"), actor: .user)
        try await h.store.softDelete(id: deleted.id, expectedRevision: 1, actor: .user)
        h.model.space = .mine
        await h.model.refresh()
        XCTAssertEqual(Set(h.model.visible.map(\.id)), [local.id, kept.id])
        XCTAssertFalse(h.model.visible.map(\.id).contains(gone.id))
        h.model.space = .jira(h.connection.id)
        XCTAssertEqual(Set(h.model.visible.map(\.id)), [kept.id], "the Jira space shows assigned, mentioned and kept")
    }

    func testQuickEntryCreatesTaskWithTokens() async throws {
        let h = try await harness()
        h.model.previewQuickEntry("Счёт @Работа #финансы !2 ^завтра")
        XCTAssertEqual(h.model.quickEntryPreview?.title, "Счёт")
        XCTAssertEqual(h.model.quickEntryPreview?.list, "Работа")
        await h.model.create(quickEntry: "Счёт @Работа #финансы !2 ^завтра")
        let created = try XCTUnwrap(h.model.visible.first { $0.title == "Счёт" })
        XCTAssertEqual(created.list, "Работа")
        XCTAssertEqual(created.tags, ["финансы"])
        XCTAssertEqual(created.priority, 2)
        XCTAssertEqual(created.due, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: h.clock.now())))
        XCTAssertEqual(created.status, .inbox)
        XCTAssertNil(h.model.quickEntryPreview, "the preview clears after creating")
    }

    func testCycleStatusRespectsBlocking() async throws {
        let h = try await harness()
        await h.model.create(quickEntry: "Блокер")
        let blocker = try XCTUnwrap(h.model.visible.first { $0.title == "Блокер" })
        await h.model.create(quickEntry: "Зависимая ~\(blocker.code)")
        let dependent = try XCTUnwrap(h.model.visible.first { $0.title == "Зависимая" })
        XCTAssertEqual(dependent.dependsOn, [blocker.id])
        await h.model.cycleStatus(id: dependent.id)
        let cycled = try XCTUnwrap(h.model.task(id: dependent.id))
        XCTAssertEqual(cycled.status, .cancelled, "a blocked task skips active and done")
        await h.model.set(status: .active, id: dependent.id)
        XCTAssertEqual(h.model.error, "Ждёт: Блокер")
        XCTAssertEqual(h.model.task(id: dependent.id)?.status, .cancelled)
        await h.model.set(status: .inbox, id: dependent.id)
        await h.model.set(status: .done, id: blocker.id)
        XCTAssertEqual(h.model.task(id: dependent.id)?.status, .active, "closing the blocker activates the dependent")
    }

    func testUndoRestoresPreviousTaskAndStopsAfterLaterEdit() async throws {
        let h = try await harness()
        await h.model.create(quickEntry: "Задача")
        let task = try XCTUnwrap(h.model.visible.first { $0.title == "Задача" })
        await h.model.set(priority: 1, id: task.id)
        XCTAssertEqual(h.model.task(id: task.id)?.priority, 1)
        await h.model.undo()
        XCTAssertEqual(h.model.task(id: task.id)?.priority, 4)
        await h.model.set(priority: 2, id: task.id)
        // An outside edit bumps the revision; the undo step no longer applies.
        let outsideFound = try await h.store.task(id: task.id)
        var outside = try XCTUnwrap(outsideFound)
        outside.title = "Снаружи"
        _ = try await h.store.update(outside, expectedRevision: outside.revision, actor: .user)
        await h.model.undo()
        XCTAssertEqual(h.model.error, "Задача менялась — отменить нельзя.")
        await h.model.refresh()
        XCTAssertEqual(h.model.task(id: task.id)?.priority, 2)
        XCTAssertEqual(h.model.task(id: task.id)?.title, "Снаружи")
    }

    func testUndoIsClearedByMirrorApply() async throws {
        let h = try await harness()
        await h.model.create(quickEntry: "Задача")
        let task = try XCTUnwrap(h.model.visible.first { $0.title == "Задача" })
        await h.model.set(priority: 1, id: task.id)
        h.adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: h.adapter.me)
        await h.model.syncNow()
        XCTAssertEqual(h.model.undoCount, 0)
        await h.model.undo()
        XCTAssertEqual(h.model.task(id: task.id)?.priority, 1, "nothing to undo after outside changes")
        XCTAssertNotNil(h.model.visible.first { $0.title == "Задача" })
    }

    func testJiraTransitionGoesThroughJournal() async throws {
        let h = try await harness()
        h.adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: h.adapter.me)
        h.adapter.transitionsByIssue["10001"] = [FakeJiraAdapter.start, FakeJiraAdapter.finish]
        await h.model.syncNow()
        let task = try XCTUnwrap(h.model.visible.first { $0.title == "Задача" })
        h.model.selected = task.id
        await h.model.refreshIssue(id: task.id)
        XCTAssertEqual(h.model.observation(id: task.id)?.transitions.map(\.id), ["11", "31"])
        await h.model.jira(.transition(FakeJiraAdapter.start, fields: [:]), id: task.id)
        let attempts = h.model.attempts(id: task.id)
        XCTAssertEqual(attempts.map(\.state), [.confirmed])
        XCTAssertEqual(h.model.observation(id: task.id)?.issue.status.name, "In Progress", "the card rereads the issue")
        XCTAssertNil(h.model.error)
    }

    func testBoardColumnsFollowProjectStatuses() async throws {
        let h = try await harness()
        h.adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: h.adapter.me)
        h.adapter.issues["10002"] = FakeJiraAdapter.issue(id: "10002", key: "QA-2", status: FakeJiraAdapter.done, assignee: h.adapter.me)
        await h.model.syncNow()
        h.model.space = .jira(h.connection.id)
        XCTAssertEqual(h.model.board.map(\.title), ["To Do", "In Progress", "Done"])
        XCTAssertEqual(h.model.board.map { $0.tasks.count }, [1, 0, 1])
    }

    func testBoardFallsBackToCategoriesWhenManyStatuses() async throws {
        let h = try await harness()
        h.adapter.statusesByProject["QA"] = (1...9).map {
            JiraStatus(id: "\($0)", name: "S\($0)", category: $0 < 4 ? .new : ($0 < 8 ? .indeterminate : .done))
        }
        h.adapter.issues["10001"] = FakeJiraAdapter.issue(
            id: "10001", key: "QA-1", status: JiraStatus(id: "5", name: "S5", category: .indeterminate), assignee: h.adapter.me)
        await h.model.syncNow()
        h.model.space = .jira(h.connection.id)
        XCTAssertEqual(h.model.board.map(\.title), ["К выполнению", "В работе", "Готово"])
        XCTAssertEqual(h.model.board.map { $0.tasks.count }, [0, 1, 0])
    }

    func testTimerElapsedTicks() async throws {
        let h = try await harness()
        await h.model.create(quickEntry: "Задача")
        let task = try XCTUnwrap(h.model.visible.first { $0.title == "Задача" })
        await h.model.startTimer(id: task.id)
        XCTAssertEqual(h.model.timer?.taskID, task.id)
        h.clock.advance(125)
        h.model.tick()
        XCTAssertEqual(h.model.timerElapsed, 125)
        await h.model.stopTimer()
        XCTAssertNil(h.model.timer)
        XCTAssertEqual(h.model.draft?.seconds, 180)
        XCTAssertEqual(h.model.draft?.taskID, task.id)
        await h.model.confirmDraft()
        XCTAssertNil(h.model.draft)
        XCTAssertEqual(h.model.entries(id: task.id).map(\.seconds), [180])
        XCTAssertEqual(h.model.summary.daySeconds, 180)
    }

    func testPreferencesPersistAcrossModels() async throws {
        let h = try await harness()
        h.model.sort = .due
        h.model.filter = .overdue
        h.model.showCompleted = false
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        let again = TasksWorkspaceModel(service: h.service, calendar: calendar, now: { h.clock.now() })
        await again.refresh()
        XCTAssertEqual(again.sort, .due)
        XCTAssertEqual(again.filter, .overdue)
        XCTAssertFalse(again.showCompleted)
    }

    private func created(_ h: Harness, _ line: String) async throws -> Task {
        await h.model.create(quickEntry: line)
        let title = line.split(separator: " ").first.map(String.init) ?? line
        return try XCTUnwrap(h.model.visible.first { $0.title.hasPrefix(title) })
    }

    func testBulkDoneSkipsBlockedAndUndoesAsOneStep() async throws {
        let h = try await harness()
        let a = try await created(h, "A")
        let b = try await created(h, "B")
        let d = try await created(h, "D")
        let c = try await created(h, "C ~\(d.code)")
        XCTAssertEqual(c.dependsOn, [d.id])
        let result = await h.model.bulkToggleDone(ids: [a.id, b.id, c.id])
        XCTAssertEqual(result.changed, 2)
        XCTAssertEqual(result.skippedBlocked, 1)
        XCTAssertEqual(h.model.task(id: a.id)?.status, .done)
        XCTAssertEqual(h.model.task(id: b.id)?.status, .done)
        XCTAssertEqual(h.model.task(id: c.id)?.status, .inbox)
        XCTAssertEqual(h.model.toasts.map(\.text).suffix(2), ["Выполнено: 2 задачи", "Пропущено заблокированных: 1"])
        XCTAssertEqual(h.model.lastAction, "Пропущено заблокированных: 1")
        XCTAssertEqual(h.model.undoCount, 1)
        await h.model.undo()
        XCTAssertEqual(h.model.task(id: a.id)?.status, .inbox)
        XCTAssertEqual(h.model.task(id: b.id)?.status, .inbox)
        XCTAssertEqual(h.model.undoCount, 0)
        let allBlocked = await h.model.bulkToggleDone(ids: [c.id])
        XCTAssertEqual(allBlocked.changed, 0)
        XCTAssertEqual(h.model.lastAction, "Заблокировано: сначала закройте зависимости")
    }

    func testBulkToggleReopensWhenAllDone() async throws {
        let h = try await harness()
        let a = try await created(h, "A")
        _ = await h.model.bulkToggleDone(ids: [a.id])
        _ = await h.model.bulkToggleDone(ids: [a.id])
        XCTAssertEqual(h.model.task(id: a.id)?.status, .active)
        XCTAssertEqual(h.model.lastAction, "Возвращено: 1 задача")
    }

    func testSnoozeUntilMondayNeverPicksToday() async throws {
        let h = try await harness()
        h.clock.advance(3 * 86_400)  // 2027-01-18, a Monday
        XCTAssertEqual(calendar.component(.weekday, from: h.clock.now()), 2)
        let a = try await created(h, "A")
        await h.model.bulkSnooze(ids: [a.id], until: .monday)
        let today = calendar.startOfDay(for: h.clock.now())
        XCTAssertEqual(h.model.task(id: a.id)?.due, calendar.date(byAdding: .day, value: 7, to: today))
        XCTAssertEqual(h.model.task(id: a.id)?.postponed, 1)
        await h.model.bulkSnooze(ids: [a.id], until: .tuesday)
        XCTAssertEqual(h.model.task(id: a.id)?.due, calendar.date(byAdding: .day, value: 8, to: today))
        await h.model.bulkSnooze(ids: [a.id], days: 0, months: 1)
        let tuesday = calendar.date(byAdding: .day, value: 8, to: today)!
        XCTAssertEqual(h.model.task(id: a.id)?.due, calendar.date(byAdding: .month, value: 1, to: tuesday), "a month from max(due, today)")
        XCTAssertEqual(h.model.task(id: a.id)?.postponed, 3)
        await h.model.bulkToday(ids: [a.id])
        XCTAssertEqual(h.model.task(id: a.id)?.due, today)
        XCTAssertEqual(h.model.lastAction, "На сегодня: 1 задача")
        let b = try await created(h, "B")
        await h.model.bulkPostpone(ids: [b.id])
        XCTAssertEqual(h.model.lastAction, "Нет срока для переноса")
        XCTAssertNil(h.model.task(id: b.id)?.due)
    }

    func testDuplicateCopiesFieldsButNotNotesOrSource() async throws {
        let h = try await harness()
        let a = try await created(h, "Исходная @Работа #тег !2 ^завтра")
        var edited = a
        edited.notes = [TaskNote(content: "секрет")]
        edited.personas = ["Боб"]
        await h.model.update(edited)
        await h.model.duplicate(id: a.id)
        let copies = h.model.visible.filter { $0.title == "Исходная" }
        XCTAssertEqual(copies.count, 2)
        let copy = try XCTUnwrap(copies.first { $0.id != a.id })
        XCTAssertEqual(copy.list, "Работа")
        XCTAssertEqual(copy.tags, ["тег"])
        XCTAssertEqual(copy.priority, 2)
        XCTAssertEqual(copy.due, a.due)
        XCTAssertEqual(copy.personas, ["Боб"])
        XCTAssertEqual(copy.notes, [])
        XCTAssertNil(copy.source)
        XCTAssertNotEqual(copy.code, a.code)
        XCTAssertEqual(h.model.lastAction, "Задача продублирована")
    }

    func testReferencesTextUsesVisibleOrder() async throws {
        let h = try await harness()
        let first = try await created(h, "Первая !1")
        let second = try await created(h, "Вторая !2")
        h.model.sort = .priority
        XCTAssertEqual(h.model.visible.map(\.id), [first.id, second.id])
        XCTAssertEqual(
            h.model.referencesText(ids: [second.id, first.id]), "to:\(first.code) Первая\nto:\(second.code) Вторая")
        XCTAssertEqual(h.model.referencesText(ids: []), "")
    }

    func testRenameAndSelectionBridge() async throws {
        let h = try await harness()
        let a = try await created(h, "Старое")
        h.model.selected = a.id
        XCTAssertEqual(h.model.selection.selected, [a.id])
        XCTAssertEqual(h.model.selection.cursor, h.model.visible.firstIndex { $0.id == a.id })
        await h.model.rename(id: a.id, title: "Новое")
        XCTAssertEqual(h.model.task(id: a.id)?.title, "Новое")
        await h.model.delete(id: a.id)
        XCTAssertNil(h.model.selected)
        XCTAssertTrue(h.model.selection.selected.isEmpty)
    }

    func testOutsideChangesToast() async throws {
        let h = try await harness()
        h.adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: h.adapter.me)
        await h.model.syncNow()
        XCTAssertEqual(h.model.toasts.map(\.text).last, "Обновлено извне")
    }

    func testNoneTasksAreFoundBySearch() async throws {
        let h = try await harness()
        let gone = try await h.store.insert(
            Task(
                title: "Ушла из выборки",
                source: TaskSource(
                    identity: ServiceIdentity(service: "jira", accountID: h.connection.id.uuidString, externalID: "9"), membership: .none)),
            actor: .provider)
        await h.model.refresh()
        h.model.space = .jira(h.connection.id)
        XCTAssertFalse(h.model.visible.map(\.id).contains(gone.id), "hidden until searched for")
        h.model.search = "ушла"
        XCTAssertTrue(h.model.visible.map(\.id).contains(gone.id), "search reaches tasks that left the selection")
        h.model.search = ""
        h.model.showLeft = true
        XCTAssertTrue(h.model.visible.map(\.id).contains(gone.id), "the «Ушедшие» switch shows them too")
    }
}
