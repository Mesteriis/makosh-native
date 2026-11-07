import Foundation
import MakoshCore
import MakoshJira
import XCTest
@testable import MakoshTasks

final class TaskJiraAttemptJournalTests: XCTestCase {
    private let connectionID = UUID()

    private func journal(_ db: TasksTestDatabase, adapter: FakeJiraAdapter) async throws -> (TaskStore, TaskJiraAttemptJournal, Task) {
        let store = try await taskStore(db)
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1")
        adapter.transitionsByIssue["10001"] = [FakeJiraAdapter.start, FakeJiraAdapter.finish]
        let identity = ServiceIdentity(service: "jira", accountID: connectionID.uuidString, externalID: "10001")
        let task = try await store.insert(Task(title: "QA-1", source: TaskSource(identity: identity, membership: .assigned)), actor: .provider)
        let journal = TaskJiraAttemptJournal(store: store) { [connectionID] id in id == connectionID ? adapter : nil }
        return (store, journal, task)
    }
    private func attempt(_ task: Task, kind: TaskJiraAttempt.Kind, payload: TaskJiraAttempt.Payload) -> TaskJiraAttempt {
        TaskJiraAttempt(taskID: task.id, connectionID: connectionID, issueID: "10001", kind: kind, payload: payload)
    }

    func testSubmitConfirmsWithResultID() async throws {
        let db = try tasksDatabase(), adapter = FakeJiraAdapter()
        let (store, journal, task) = try await journal(db, adapter: adapter)
        let result = await journal.submit(attempt(task, kind: .comment, payload: .comment(text: "Готово", adf: JiraADF.document(fromText: "Готово"))))
        XCTAssertEqual(result.state, .confirmed)
        XCTAssertEqual(result.resultID, "c101")
        XCTAssertNotNil(result.resolvedAt)
        let stored = try await store.attempts(taskID: task.id)
        XCTAssertEqual(stored.map(\.state), [.confirmed])
    }

    func testSubmitRejectedKeepsCodeOnly() async throws {
        let db = try tasksDatabase(), adapter = FakeJiraAdapter()
        let (_, journal, task) = try await journal(db, adapter: adapter)
        adapter.failNextWrite = .http(status: 400)
        let result = await journal.submit(attempt(task, kind: .assignee, payload: .assignee(accountID: "bob-1")))
        XCTAssertEqual(result.state, .rejected)
        XCTAssertEqual(result.reason, "http.400")
    }

    func testTimeoutLeavesUnknownAndNeverRetries() async throws {
        let db = try tasksDatabase(), adapter = FakeJiraAdapter()
        let (store, journal, task) = try await journal(db, adapter: adapter)
        adapter.failNextWrite = .transport(code: "timedOut")
        let payload = TaskJiraAttempt.Payload.worklog(started: Date(), seconds: 600, comment: nil, entryID: UUID())
        let first = await journal.submit(attempt(task, kind: .worklog, payload: payload))
        XCTAssertEqual(first.state, .unknown)
        XCTAssertEqual(first.reason, "transport.timedOut")
        await journal.resume()
        let second = await journal.submit(attempt(task, kind: .worklog, payload: payload))
        XCTAssertEqual(second.id, first.id, "the open attempt is returned, not a new one")
        XCTAssertEqual(second.state, .unknown)
        XCTAssertEqual(adapter.calls.filter { if case .addWorklog = $0 { true } else { false } }.count, 1)
        let open = try await store.openAttempts()
        XCTAssertEqual(open.map(\.id), [first.id])
    }

    func testResumeTurnsSentIntoUnknown() async throws {
        let db = try tasksDatabase(), adapter = FakeJiraAdapter()
        let (store, journal, task) = try await journal(db, adapter: adapter)
        var sent = attempt(task, kind: .comment, payload: .comment(text: "x", adf: JiraADF.document(fromText: "x")))
        sent = try await store.insertAttempt(sent)
        sent = try await store.updateAttempt(sent.with(state: .sent), expectedState: .queued)
        await journal.resume()
        let stored = try await store.attempts(taskID: task.id)
        XCTAssertEqual(stored.first?.state, .unknown)
        XCTAssertEqual(stored.first?.reason, "перезапуск")
    }

    func testResolveWorklogByExactMatch() async throws {
        let db = try tasksDatabase(), adapter = FakeJiraAdapter()
        let (_, journal, task) = try await journal(db, adapter: adapter)
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        adapter.failNextWrite = .transport(code: "networkFailure")
        let unknown = await journal.submit(attempt(task, kind: .worklog, payload: .worklog(started: started, seconds: 600, comment: "созвон", entryID: UUID())))
        XCTAssertEqual(unknown.state, .unknown)
        // Jira did record it after all.
        adapter.worklogsByIssue["10001"] = [JiraWorklog(id: "w7", author: adapter.me, started: started, seconds: 600, commentText: "созвон")]
        let resolved = await journal.resolve(unknown.id)
        XCTAssertEqual(resolved.state, .confirmed)
        XCTAssertEqual(resolved.resultID, "w7")
    }

    func testResolveWorklogAmbiguousStaysUnknown() async throws {
        let db = try tasksDatabase(), adapter = FakeJiraAdapter()
        let (_, journal, task) = try await journal(db, adapter: adapter)
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        adapter.failNextWrite = .transport(code: "networkFailure")
        let unknown = await journal.submit(attempt(task, kind: .worklog, payload: .worklog(started: started, seconds: 600, comment: nil, entryID: UUID())))
        adapter.worklogsByIssue["10001"] = [
            JiraWorklog(id: "w7", author: adapter.me, started: started, seconds: 600), JiraWorklog(id: "w8", author: adapter.me, started: started, seconds: 600),
        ]
        let resolved = await journal.resolve(unknown.id)
        XCTAssertEqual(resolved.state, .unknown)
        XCTAssertEqual(resolved.reason, "несколько совпадений")
        adapter.worklogsByIssue["10001"] = []
        let rejected = await journal.resolve(unknown.id)
        XCTAssertEqual(rejected.state, .rejected)
        XCTAssertEqual(rejected.reason, "не найдено")
    }

    func testResolveTransitionByStatus() async throws {
        let db = try tasksDatabase(), adapter = FakeJiraAdapter()
        let (_, journal, task) = try await journal(db, adapter: adapter)
        adapter.failNextWrite = .transport(code: "timedOut")
        let unknown = await journal.submit(attempt(task, kind: .transition, payload: .transition(id: "11", toStatusID: "2", fields: [:])))
        XCTAssertEqual(unknown.state, .unknown)
        let notYet = await journal.resolve(unknown.id)
        XCTAssertEqual(notYet.state, .rejected, "the issue still shows To Do")
        adapter.failNextWrite = .transport(code: "timedOut")
        let again = await journal.submit(attempt(task, kind: .transition, payload: .transition(id: "11", toStatusID: "2", fields: [:])))
        adapter.issues["10001"]?.status = FakeJiraAdapter.inProgress
        let confirmed = await journal.resolve(again.id)
        XCTAssertEqual(confirmed.state, .confirmed)
    }

    func testDismissRejects() async throws {
        let db = try tasksDatabase(), adapter = FakeJiraAdapter()
        let (_, journal, task) = try await journal(db, adapter: adapter)
        adapter.failNextWrite = .transport(code: "timedOut")
        let unknown = await journal.submit(attempt(task, kind: .fields, payload: .fields(JiraIssuePatch(summary: "x"))))
        let dismissed = await journal.dismiss(unknown.id)
        XCTAssertEqual(dismissed?.state, .rejected)
        XCTAssertEqual(dismissed?.reason, "отказ пользователя")
    }

    func testStoreRefusesInvalidStateTransition() async throws {
        let db = try tasksDatabase(), adapter = FakeJiraAdapter()
        let (store, _, task) = try await journal(db, adapter: adapter)
        let inserted = try await store.insertAttempt(attempt(task, kind: .comment, payload: .comment(text: "x", adf: Data())))
        do {
            _ = try await store.updateAttempt(inserted.with(state: .confirmed), expectedState: .queued)
            XCTFail("queued → confirmed is not allowed")
        } catch let error as TaskStoreError { XCTAssertEqual(error, .invalidTransition) }
        let sent = try await store.updateAttempt(inserted.with(state: .sent), expectedState: .queued)
        do {
            _ = try await store.updateAttempt(sent.with(state: .confirmed), expectedState: .queued)
            XCTFail("expected state mismatch must fail")
        } catch let error as TaskStoreError { XCTAssertEqual(error, .invalidTransition) }
    }
}
