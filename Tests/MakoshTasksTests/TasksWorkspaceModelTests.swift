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
        h.model.sortState = TasksSortState(field: .priority, descending: false)
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

    func testPreferencesV2RoundTrip() async throws {
        let h = try await harness()
        h.model.sortState = TasksSortState(field: .due, descending: true)
        h.model.filters.toggle(agenda: .overdue)
        h.model.filters.toggle(tag: "релиз")
        h.model.filters.actualOnly = true
        h.model.condense = true
        h.model.showPlanner = true
        h.model.showCalendar = false
        h.model.plannerWidthPercent = 55
        h.model.collapsedSections = ["hotkeys", "tags"]
        try await _Concurrency.Task.sleep(for: .milliseconds(80))
        let again = TasksWorkspaceModel(service: h.service, calendar: calendar, now: { h.clock.now() })
        await again.refresh()
        XCTAssertEqual(again.sortState, TasksSortState(field: .due, descending: true))
        XCTAssertEqual(again.filters.agenda, .overdue)
        XCTAssertEqual(again.filters.tag, "релиз")
        XCTAssertTrue(again.filters.actualOnly)
        XCTAssertTrue(again.condense)
        XCTAssertTrue(again.showPlanner)
        XCTAssertFalse(again.showCalendar)
        XCTAssertEqual(again.plannerWidthPercent, 55)
        XCTAssertEqual(again.collapsedSections, ["hotkeys", "tags"])
    }

    func testFiltersCombineAndCountsIncludeOverdue() async throws {
        let h = try await harness()
        let overdue = try await created(h, "Просроченная #a ^вчера")
        let today = try await created(h, "Сегодняшняя #b ^сегодня")
        _ = try await created(h, "Без срока #a")
        h.model.filters.toggle(agenda: .today)
        XCTAssertEqual(Set(h.model.visible.map(\.id)), [overdue.id, today.id], "today includes the overdue")
        XCTAssertEqual(h.model.agendaCounts[.today], 2)
        XCTAssertEqual(h.model.agendaCounts[.overdue], 1)
        XCTAssertEqual(h.model.agendaCounts[.week], 2)
        XCTAssertEqual(h.model.foundCount, 2)
        h.model.filters.toggle(tag: "a")
        XCTAssertEqual(h.model.visible.map(\.id), [overdue.id])
        XCTAssertEqual(h.model.tagCounts["a"], 2)
        XCTAssertEqual(h.model.statusCounts[.inbox], 3)
        XCTAssertEqual(h.model.totalCount, 3)
        h.model.clearAll()
        XCTAssertEqual(h.model.visible.count, 3)
        XCTAssertNil(h.model.foundCount)
    }

    func testOverdueFloatToTopUnderDivider() async throws {
        let h = try await harness()
        let urgent = try await created(h, "Срочная !1")
        let late = try await created(h, "Просроченная !4 ^вчера")
        h.model.sortState = TasksSortState(field: .priority, descending: false)
        XCTAssertEqual(h.model.visible.map(\.id), [late.id, urgent.id], "overdue floats above a higher priority")
        XCTAssertEqual(h.model.overdueCount, 1)
        _ = await h.model.bulkToggleDone(ids: [late.id])
        XCTAssertEqual(h.model.overdueCount, 0, "a done task is no longer overdue")
    }

    func testSearchSwapsKeyboardLayoutAndAcceptsRefs() async throws {
        let h = try await harness()
        let hello = try await created(h, "Привет")
        let other = try await created(h, "Другая")
        h.model.search = "ghbdtn"
        XCTAssertEqual(h.model.visible.map(\.id), [hello.id])
        h.model.search = "to:" + other.code.lowercased()
        XCTAssertEqual(h.model.visible.map(\.id), [other.id])
        h.model.search = ""
        XCTAssertEqual(h.model.visible.count, 2)
    }

    func testEscapeCascade() async throws {
        let h = try await harness()
        let a = try await created(h, "A")
        h.model.filters.toggle(list: "Нет")
        h.model.search = "a"
        h.model.selected = a.id
        XCTAssertEqual(h.model.escape(), .selection)
        XCTAssertTrue(h.model.selection.selected.isEmpty)
        XCTAssertEqual(h.model.escape(), .search)
        XCTAssertEqual(h.model.search, "")
        XCTAssertEqual(h.model.escape(), .filters)
        XCTAssertFalse(h.model.filters.isFiltering)
        XCTAssertEqual(h.model.escape(), .nothing)
    }

    func testGroupByFlowClustersAtFirstOccurrence() async throws {
        let h = try await harness()
        let a = try await created(h, "A !1")
        let b = try await created(h, "B !2")
        let c = try await created(h, "C !3")
        let d = try await created(h, "D !4")
        for id in [a.id, c.id] {
            var task = try XCTUnwrap(h.model.task(id: id))
            task.flowID = "Релиз"
            await h.model.update(task)
        }
        h.model.sortState = TasksSortState(field: .priority, descending: false)
        XCTAssertEqual(h.model.visible.map(\.id), [a.id, b.id, c.id, d.id])
        h.model.filters.groupByFlow = true
        XCTAssertEqual(h.model.visible.map(\.id), [a.id, c.id, b.id, d.id], "flow tasks gather at the first one")
        XCTAssertEqual(h.model.flowGroups.map(\.flow), ["Релиз", nil])
        XCTAssertEqual(h.model.flowGroups.map { $0.tasks.count }, [2, 2])
        h.model.filters.toggle(flow: "Релиз")
        XCTAssertEqual(h.model.visible.map(\.id), [a.id, c.id], "a pinned flow is not grouped again")
        XCTAssertEqual(h.model.flowGroups.map(\.flow), [nil])
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

    func testQuickEntryPrefillsFromFilters() async throws {
        let h = try await harness()
        h.model.filters.toggle(agenda: .tomorrow)
        h.model.filters.toggle(list: "Работа")
        h.model.filters.toggle(persona: "Боб")
        h.model.filters.toggle(tag: "релиз")
        h.model.quickEntry.typed("Созвон ", extractURLs: true)
        await h.model.create()
        let task = try XCTUnwrap(h.model.tasks.first { $0.title == "Созвон" })
        XCTAssertEqual(task.due, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: h.clock.now())))
        XCTAssertEqual(task.list, "Работа")
        XCTAssertEqual(task.personas, ["Боб"])
        XCTAssertEqual(task.tags, ["релиз"])
        XCTAssertTrue(h.model.quickEntry.isEmpty, "the field clears after creating")
        h.model.filters.clearFilters()
        h.model.filters.toggle(status: .active)
        h.model.quickEntry.typed("Сразу в работе ", extractURLs: true)
        await h.model.create()
        XCTAssertEqual(h.model.tasks.first { $0.title == "Сразу в работе" }?.status, .active)
    }

    func testQuickEntryToastNamesTheTask() async throws {
        let h = try await harness()
        for text in ["Счёт @Работа ", "Счёт !1 ", "Счёт ^завтра "] { h.model.quickEntry.typed(text, extractURLs: true) }
        XCTAssertEqual(h.model.quickEntry.chips.map(\.raw), ["@Работа", "!1", "^завтра"])
        XCTAssertEqual(h.model.quickEntryPreview?.title, "Счёт")
        await h.model.create()
        let expectedDay = TaskDateFormat.dmy.string(
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: h.clock.now()))!, calendar: calendar)
        XCTAssertEqual(h.model.lastAction, "Создана: Счёт · \(expectedDay) · P1 · @Работа")
        XCTAssertNil(h.model.quickEntryPreview)
    }

    func testStartNextActivatesFirstReady() async throws {
        let h = try await harness()
        let first = try await created(h, "Первая >>Релиз")
        let second = try await created(h, "Вторая >>Релиз ~\(first.code)")
        XCTAssertEqual(h.model.flows, ["Релиз"])
        XCTAssertEqual(h.model.flowProgress("Релиз").total, 2)
        await h.model.startNext(inFlow: "Релиз")
        XCTAssertEqual(h.model.task(id: first.id)?.status, .active)
        XCTAssertEqual(h.model.task(id: second.id)?.status, .inbox)
        XCTAssertEqual(h.model.lastAction, "Задача запущена")
        await h.model.saveFlow(TaskFlow(name: "Релиз", description: "Выпуск", color: TaskFlow.palette[2]))
        XCTAssertEqual(h.model.flowMeta["Релиз"]?.description, "Выпуск")
        h.model.filters.toggle(flow: "Релиз")
        XCTAssertEqual(h.model.activeFlow, "Релиз")
        XCTAssertEqual(Set(h.model.flowTasks.map(\.id)), [first.id, second.id])
        await h.model.deleteFlow(name: "Релиз")
        XCTAssertNil(h.model.filters.flow, "deleting the pinned flow clears its filter")
        XCTAssertNil(h.model.task(id: first.id)?.flowID)
        XCTAssertTrue(h.model.flows.isEmpty)
    }

    func testPersonaCountsAndFilter() async throws {
        let h = try await harness()
        let bob = try await created(h, "Для Боба /Боб")
        _ = try await created(h, "Для обоих /Боб /Алиса")
        XCTAssertEqual(h.model.personas, ["Алиса", "Боб"])
        XCTAssertEqual(h.model.personaCounts["Боб"], 2)
        h.model.filters.toggle(persona: "Алиса")
        XCTAssertEqual(h.model.visible.map(\.title), ["Для обоих"])
        await h.model.setPersonas(id: bob.id, ["Алиса"])
        XCTAssertEqual(h.model.visible.count, 2)
        await h.model.setFlow(id: bob.id, name: "Ремонт")
        XCTAssertEqual(h.model.flowCounts["Ремонт"], 1)
    }

    func testMoveSlotIsUndoable() async throws {
        let h = try await harness()
        let a = try await created(h, "Задача")
        await h.model.loadPlanner()
        await h.model.dropTasks([a.id], at: 10 * 60)
        let slot = try XCTUnwrap(h.model.slots.first)
        XCTAssertEqual(slot.start, 10 * 60)
        XCTAssertEqual(slot.end, 11 * 60)
        XCTAssertEqual(h.model.plannedTaskIDs, [a.id])
        await h.model.moveSlot(id: slot.id, to: 14 * 60)
        XCTAssertEqual(h.model.slots.first?.start, 14 * 60)
        XCTAssertEqual(h.model.slots.first?.end, 15 * 60)
        await h.model.undo()
        XCTAssertEqual(h.model.slots.first?.start, 10 * 60, "the move comes back with one undo")
        await h.model.resizeSlot(id: slot.id, end: 12 * 60)
        XCTAssertEqual(h.model.task(id: a.id)?.estimateMinutes, 120, "resizing writes the estimate")
        await h.model.removeSlot(id: slot.id)
        XCTAssertTrue(h.model.slots.isEmpty)
        await h.model.undo()
        XCTAssertEqual(h.model.slots.count, 1, "removal is undoable too")
        await h.model.dropTasks([a.id], at: 9 * 60)
        XCTAssertEqual(h.model.slots.count, 1, "a task already in the plan is not added twice")
        XCTAssertEqual(h.model.plannerSummary.planned, 120)
    }

    func testCreateHereSchedulesTheNewTask() async throws {
        let h = try await harness()
        await h.model.loadPlanner()
        await h.model.blockSlot(at: 10 * 60 + 30)
        XCTAssertEqual(h.model.slots.map(\.kind), [.blocked])
        h.model.createTaskHere(at: 10 * 60)
        h.model.quickEntry.typed("Созвон ", extractURLs: true)
        await h.model.create()
        let task = try XCTUnwrap(h.model.tasks.first { $0.title == "Созвон" })
        let slot = try XCTUnwrap(h.model.slots.first { $0.taskID == task.id })
        XCTAssertEqual(slot.start, 10 * 60)
        XCTAssertEqual(slot.end, 10 * 60 + 30, "only until the blocked slot")
        let blocked = try XCTUnwrap(h.model.slots.first { $0.kind == .blocked })
        await h.model.updateSlot(id: blocked.id, title: "Обед", recurrence: .daily)
        XCTAssertEqual(h.model.slots.first { $0.kind == .blocked }?.title, "Обед")
        XCTAssertEqual(h.model.slots.first { $0.kind == .blocked }?.recurrence, .daily)
    }

    func testPlannerDayAdvancesAtMidnightOnlyWhenOnToday() async throws {
        let h = try await harness()
        await h.model.loadPlanner()
        let today = calendar.startOfDay(for: h.clock.now())
        XCTAssertEqual(h.model.plannerDay, today)
        h.clock.advance(86_400)
        h.model.tick()
        XCTAssertEqual(h.model.plannerDay, calendar.date(byAdding: .day, value: 1, to: today), "midnight moves a planner that showed today")
        let pinned = calendar.date(byAdding: .day, value: 5, to: today)!
        h.model.plannerDay = pinned
        h.clock.advance(86_400)
        h.model.tick()
        XCTAssertEqual(h.model.plannerDay, pinned, "an explicit day stays")
    }

    func testMirrorClosingFocusedTaskQueuesDraft() async throws {
        let h = try await harness()
        h.adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: h.adapter.me)
        await h.model.syncNow()
        let jira = try XCTUnwrap(h.model.visible.first { $0.title == "Задача" })
        let local = try await created(h, "Локальная")
        await h.model.setFocusEnabled(true)
        XCTAssertTrue(h.model.focusEnabled)
        await h.model.focus(id: jira.id)
        XCTAssertEqual(h.model.timer?.taskID, jira.id)
        XCTAssertEqual(h.model.focusState.active?.taskID, jira.id)
        h.clock.advance(600)
        await h.model.logManual(id: local.id, startedAt: h.clock.now(), seconds: 300, note: "вручную")
        let first = try XCTUnwrap(h.model.draft)
        XCTAssertEqual(first.taskID, local.id)
        h.adapter.issues["10001"]?.status = FakeJiraAdapter.done
        await h.model.syncNow()
        XCTAssertEqual(h.model.task(id: jira.id)?.status, .done)
        XCTAssertEqual(h.model.draft?.id, first.id, "the open draft stays until it is settled")
        XCTAssertNil(h.model.timer)
        XCTAssertTrue(h.model.focusState.sessions.isEmpty)
        await h.model.confirmDraft()
        let queued = try XCTUnwrap(h.model.draft)
        XCTAssertEqual(queued.taskID, jira.id)
        XCTAssertEqual(queued.reason, "задача закрыта в Jira")
        XCTAssertGreaterThanOrEqual(queued.seconds, 600)
        await h.model.discardDraft()
        XCTAssertNil(h.model.draft)
        XCTAssertNil(h.model.timer, "discarding a closed task's draft does not restart its timer")
    }

    func testFocusDoneMarksTaskDoneAndOpensDraft() async throws {
        let h = try await harness()
        let a = try await created(h, "В фокусе")
        await h.model.setFocusEnabled(true)
        await h.model.startTimer(id: a.id)
        XCTAssertEqual(h.model.focusState.active?.taskID, a.id, "with the panel on, the timer is a focus session")
        h.clock.advance(120)
        await h.model.focusDone(id: a.id)
        XCTAssertEqual(h.model.task(id: a.id)?.status, .done)
        XCTAssertEqual(h.model.draft?.taskID, a.id)
        XCTAssertEqual(h.model.draft?.seconds, 120)
        XCTAssertNil(h.model.timer)
        await h.model.confirmDraft()
        XCTAssertEqual(h.model.entries(id: a.id).map(\.seconds), [120])
        await h.model.setFocusEnabled(false)
        XCTAssertFalse(h.model.focusEnabled)
    }

    func testStopTimerWithFocusOnEndsTheSession() async throws {
        let h = try await harness()
        let a = try await created(h, "A")
        await h.model.setFocusEnabled(true)
        await h.model.focus(id: a.id)
        h.clock.advance(60)
        await h.model.stopTimer()
        XCTAssertEqual(h.model.draft?.taskID, a.id)
        XCTAssertTrue(h.model.focusState.sessions.isEmpty)
        await h.model.discardDraft()
        XCTAssertEqual(h.model.timer?.taskID, a.id, "discarding an open task's timer draft restores the timer")
        XCTAssertEqual(h.model.focusState.active?.taskID, a.id, "and the session with it")
        XCTAssertGreaterThanOrEqual(h.model.focusState.workSeconds(of: a.id, now: h.clock.now()), 60, "the session's time comes back too")
        XCTAssertGreaterThanOrEqual(h.model.timerElapsed, 60)
    }

    func testUndoPathGoesThroughTheSameRules() async throws {
        let h = try await harness()
        let x = try await created(h, "X")
        let y = try await created(h, "Y ~\(x.code)")
        await h.model.set(status: .active, id: x.id)
        await h.model.set(status: .done, id: x.id)
        XCTAssertEqual(h.model.task(id: y.id)?.status, .active, "closing X activates Y")
        await h.model.undo()
        XCTAssertEqual(h.model.task(id: x.id)?.status, .active)
        XCTAssertEqual(h.model.task(id: y.id)?.status, .inbox, "reopening X takes the activation back: no active-but-blocked task")
    }

    func testBulkCycleLeavesCascadedDependentAlone() async throws {
        let h = try await harness()
        let x = try await created(h, "X")
        let y = try await created(h, "Y ~\(x.code)")
        await h.model.set(status: .active, id: x.id)
        let result = await h.model.bulkCycle(ids: [x.id, y.id])
        XCTAssertEqual(h.model.task(id: x.id)?.status, .done)
        XCTAssertEqual(h.model.task(id: y.id)?.status, .active, "Y was moved by X's closing and is not cycled again")
        XCTAssertEqual(result.changed, 1)
        XCTAssertEqual(result.activated, ["Y"])
        await h.model.undo()
        XCTAssertEqual(h.model.task(id: x.id)?.status, .active)
        XCTAssertEqual(h.model.task(id: y.id)?.status, .inbox)
    }

    func testCalendarMonthAndDaySelection() async throws {
        let h = try await harness()
        let due = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: h.clock.now()))!
        let a = try await created(h, "Со сроком ^+3d")
        _ = try await created(h, "Без срока")
        XCTAssertEqual(h.model.calendarMonth.year, calendar.component(.year, from: h.clock.now()))
        XCTAssertEqual(h.model.calendarMonth.month, calendar.component(.month, from: h.clock.now()))
        XCTAssertEqual(h.model.dueDays, [due])
        h.model.filters.toggle(agenda: .week)
        XCTAssertEqual(
            h.model.agendaRange?.upperBound, calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: h.clock.now())))
        h.model.selectDay(due)
        XCTAssertNil(h.model.filters.agenda, "a day replaces the agenda")
        XCTAssertEqual(h.model.visible.map(\.id), [a.id])
        XCTAssertEqual(h.model.filters.chips.last?.kind, .day)
        h.model.selectDay(due)
        XCTAssertNil(h.model.filters.day)
        h.model.calendarMonth = h.model.calendarMonth.next()
        XCTAssertEqual(
            h.model.calendarMonth.month, calendar.component(.month, from: calendar.date(byAdding: .month, value: 1, to: h.clock.now())!))
    }
}
