import Foundation
import MakoshCore
import MakoshJira
import XCTest
@testable import MakoshTasks

final class TaskTimeServiceTests: XCTestCase {
    private let connectionID = UUID()
    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private struct Harness {
        let store: TaskStore
        let adapter: FakeJiraAdapter
        let journal: TaskJiraAttemptJournal
        let service: TaskTimeService
        let clock: Clock
        let jiraTask: Task
        let localTask: Task
    }

    private func harness(_ db: TasksTestDatabase, suggestWorklog: Bool = true) async throws -> Harness {
        let store = try await taskStore(db)
        let clock = Clock()
        let adapter = FakeJiraAdapter()
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: adapter.me)
        let connection = JiraConnection(
            id: connectionID, name: "Работа", origin: URL(string: "https://jira.test")!, email: "me@example.com",
            suggestWorklog: suggestWorklog)
        try await store.saveConnection(connection)
        let identity = ServiceIdentity(service: "jira", accountID: connectionID.uuidString, externalID: "10001")
        let jiraTask = try await store.insert(
            Task(title: "QA-1", source: TaskSource(identity: identity, membership: .assigned)), actor: .provider)
        let localTask = try await store.insert(Task(title: "Локальная"), actor: .user)
        let journal = TaskJiraAttemptJournal(store: store, now: { clock.now() }) { [connectionID] id in id == connectionID ? adapter : nil }
        let service = TaskTimeService(store: store, journal: journal, now: { clock.now() })
        return Harness(
            store: store, adapter: adapter, journal: journal, service: service, clock: clock, jiraTask: jiraTask, localTask: localTask)
    }

    func testStartPersistsTimerAcrossReopen() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        let timer = try await h.service.start(taskID: h.localTask.id, note: "пишу")
        XCTAssertEqual(timer.taskID, h.localTask.id)
        XCTAssertEqual(timer.startedAt, h.clock.now())
        let again = TaskStore(connectionString: db.connectionString, schema: db.schema)
        try await again.open()
        let reloaded = try await again.timer()
        XCTAssertEqual(reloaded, timer)
    }

    func testStopRoundsUpToWholeMinute() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        _ = try await h.service.start(taskID: h.localTask.id, note: "")
        h.clock.advance(90)
        let draft = try await h.service.stop()
        XCTAssertEqual(draft.seconds, 120)
        XCTAssertEqual(draft.source, .timer)
        XCTAssertFalse(draft.sendToJira, "a local task has no worklog")
        let cleared = try await h.store.timer()
        XCTAssertNil(cleared)
    }

    func testStartWhileRunningIsRefused() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        _ = try await h.service.start(taskID: h.localTask.id, note: "")
        do {
            _ = try await h.service.start(taskID: h.jiraTask.id, note: "")
            XCTFail("a second timer must be refused")
        } catch let error as TasksFailure { XCTAssertEqual(error, .timerRunning(h.localTask.id)) }
        _ = try await h.service.start(taskID: h.localTask.id, note: "same task restarts")
    }

    func testConfirmCreatesEntryAndWorklogAttemptForJiraTask() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        _ = try await h.service.start(taskID: h.jiraTask.id, note: "созвон")
        h.clock.advance(600)
        let draft = try await h.service.stop()
        XCTAssertTrue(draft.sendToJira)
        let entry = try await h.service.confirm(draft)
        XCTAssertEqual(entry.seconds, 600)
        XCTAssertEqual(entry.worklogState, .confirmed)
        XCTAssertEqual(entry.worklogID, "w101")
        XCTAssertNotNil(entry.attemptID)
        XCTAssertEqual(h.adapter.calls.filter { if case .addWorklog = $0 { true } else { false } }.count, 1)
        let attempts = try await h.store.attempts(taskID: h.jiraTask.id)
        XCTAssertEqual(attempts.map(\.state), [.confirmed])
    }

    func testConfirmWithoutJiraKeepsLocalEntry() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        let draft = h.service.draft(
            manual: h.jiraTask.id, startedAt: h.clock.now(), seconds: 300, note: "вручную", meetingID: nil, sendToJira: false)
        let entry = try await h.service.confirm(draft)
        XCTAssertEqual(entry.source, .manual)
        XCTAssertEqual(entry.worklogState, .none)
        XCTAssertNil(entry.attemptID)
        XCTAssertTrue(h.adapter.calls.isEmpty)
        let entries = try await h.store.entries(taskID: h.jiraTask.id)
        XCTAssertEqual(entries.map(\.id), [entry.id])
    }

    func testConfirmingTheSameDraftTwiceCreatesOneEntry() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        _ = try await h.service.start(taskID: h.jiraTask.id, note: "")
        h.clock.advance(120)
        let draft = try await h.service.stop()
        _ = try await h.service.confirm(draft)
        do {
            _ = try await h.service.confirm(draft)
            XCTFail("the same draft cannot be confirmed twice")
        } catch let error as TaskStoreError { XCTAssertEqual(error, .duplicate) }
        let entries = try await h.store.entries(taskID: h.jiraTask.id)
        XCTAssertEqual(entries.count, 1)
        let attempts = try await h.store.attempts(taskID: h.jiraTask.id)
        XCTAssertEqual(attempts.count, 1)
    }

    func testConfirmedEntryIsLockedForEditAndDelete() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        let draft = h.service.draft(
            manual: h.jiraTask.id, startedAt: h.clock.now(), seconds: 300, note: "a", meetingID: nil, sendToJira: true)
        var entry = try await h.service.confirm(draft)
        XCTAssertEqual(entry.worklogState, .confirmed)
        entry.seconds = 900
        do {
            _ = try await h.service.update(entry)
            XCTFail("duration is locked")
        } catch let error as TasksFailure { XCTAssertEqual(error, .entryLocked) }
        entry.seconds = 300
        entry.note = "новое примечание"
        let noted = try await h.service.update(entry)
        XCTAssertEqual(noted.note, "новое примечание")
        do {
            try await h.service.delete(entryID: entry.id)
            XCTFail("deletion is locked")
        } catch let error as TasksFailure { XCTAssertEqual(error, .entryLocked) }
        let still = try await h.store.entries(taskID: h.jiraTask.id)
        XCTAssertEqual(still.count, 1)
    }

    func testWorklogDeletedInJiraMarksEntry() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        let draft = h.service.draft(
            manual: h.jiraTask.id, startedAt: h.clock.now(), seconds: 300, note: "a", meetingID: nil, sendToJira: true)
        let entry = try await h.service.confirm(draft)
        try await h.service.applyWorklogs([], taskID: h.jiraTask.id)
        let after = try await h.store.entries(taskID: h.jiraTask.id)
        XCTAssertEqual(after.first?.worklogState, .deletedInJira)
        XCTAssertEqual(after.first?.id, entry.id)
    }

    func testWorklogChangedInJiraUpdatesEntry() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        let draft = h.service.draft(
            manual: h.jiraTask.id, startedAt: h.clock.now(), seconds: 300, note: "a", meetingID: nil, sendToJira: true)
        let entry = try await h.service.confirm(draft)
        let moved = h.clock.now().addingTimeInterval(3600)
        try await h.service.applyWorklogs(
            [JiraWorklog(id: entry.worklogID!, author: h.adapter.me, started: moved, seconds: 1200)], taskID: h.jiraTask.id)
        let after = try await h.store.entries(taskID: h.jiraTask.id)
        XCTAssertEqual(after.first?.seconds, 1200)
        XCTAssertEqual(after.first?.startedAt, moved)
        XCTAssertEqual(after.first?.worklogState, .confirmed)
    }

    func testDaySummaryUsesLocalCalendar() async throws {
        let db = try tasksDatabase(), h = try await harness(db)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let today = calendar.startOfDay(for: h.clock.now())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let lastWeek = calendar.date(byAdding: .day, value: -9, to: today)!
        for (start, seconds) in [(today.addingTimeInterval(3600), 600), (yesterday.addingTimeInterval(3600), 1200), (lastWeek, 3000)] {
            _ = try await h.service.confirm(
                h.service.draft(manual: h.localTask.id, startedAt: start, seconds: seconds, note: "", meetingID: nil, sendToJira: false))
        }
        let summary = try await h.service.summary(day: h.clock.now(), calendar: calendar)
        XCTAssertEqual(summary.daySeconds, 600)
        XCTAssertEqual(summary.weekSeconds, 1800)
    }
}
