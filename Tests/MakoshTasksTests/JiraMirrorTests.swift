import Foundation
import MakoshCore
import MakoshJira
import XCTest
@testable import MakoshTasks

final class JiraMirrorTests: XCTestCase {
    private let connectionID = UUID()
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private func mirror(_ store: TaskStore, adapter: FakeJiraAdapter, mentions: Bool = true) -> JiraMirror {
        let clock = now
        return JiraMirror(store: store, connectionID: connectionID, adapter: adapter, accountID: "me-1", mentions: mentions, now: { clock })
    }
    private func identity(_ issueID: String) -> ServiceIdentity {
        ServiceIdentity(service: "jira", accountID: connectionID.uuidString, externalID: issueID)
    }
    private var me: JiraUser { JiraUser(accountID: "me-1", displayName: "Я") }

    func testNewAssignedIssueBecomesInboxTask() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", summary: "Счёт", assignee: me)
        let result = await mirror(store, adapter: adapter).sync(full: true)
        XCTAssertEqual(result.applied, 1)
        XCTAssertNil(result.failure)
        let taskFound = try await store.task(source: identity("10001"))
        let task = try XCTUnwrap(taskFound)
        XCTAssertEqual(task.status, .inbox)
        XCTAssertEqual(task.priority, 4)
        XCTAssertEqual(task.title, "Счёт")
        XCTAssertEqual(task.url, URL(string: "https://jira.test/browse/QA-1"))
        XCTAssertEqual(task.source?.membership, .assigned)
        let observation = try await store.latestObservation(taskID: task.id)
        XCTAssertEqual(observation?.issue.key, "QA-1")
        XCTAssertTrue(adapter.jqls.first?.contains("assignee = currentUser()") == true)
        XCTAssertTrue(adapter.jqls.first?.contains("comment ~ \"me-1\"") == true)
    }

    func testMentionedIssueIsMarkedMentioned() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        adapter.issues["10002"] = FakeJiraAdapter.issue(
            id: "10002", key: "QA-2", assignee: JiraUser(accountID: "bob-1", displayName: "Боб"))
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let taskFound = try await store.task(source: identity("10002"))
        let task = try XCTUnwrap(taskFound)
        XCTAssertEqual(task.source?.membership, .mentioned)
    }

    func testChangedIssueAppendsObservationAndKeepsLocalLayer() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", summary: "Счёт", assignee: me)
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let taskFound = try await store.task(source: identity("10001"))
        var task = try XCTUnwrap(taskFound)
        task.priority = 1
        task.list = "Работа"
        task.status = .active
        task = try await store.update(task, expectedRevision: task.revision, actor: .user)
        adapter.issues["10001"]?.summary = "Счёт за ноябрь"
        adapter.issues["10001"]?.status = FakeJiraAdapter.inProgress
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let afterFound = try await store.task(source: identity("10001"))
        let after = try XCTUnwrap(afterFound)
        XCTAssertEqual(after.priority, 1)
        XCTAssertEqual(after.list, "Работа")
        XCTAssertEqual(after.status, .active)
        XCTAssertEqual(after.title, "Счёт за ноябрь", "an untouched title follows Jira")
        let observations = try await store.observations(taskID: after.id, limit: 10)
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations.first?.issue.status.name, "In Progress")
    }

    func testUserEditedTitleIsNotOverwritten() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", summary: "Счёт", assignee: me)
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let taskFound = try await store.task(source: identity("10001"))
        var task = try XCTUnwrap(taskFound)
        task.title = "Мой заголовок"
        _ = try await store.update(task, expectedRevision: task.revision, actor: .user)
        adapter.issues["10001"]?.summary = "Новое в Jira"
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let afterFound = try await store.task(source: identity("10001"))
        let after = try XCTUnwrap(afterFound)
        XCTAssertEqual(after.title, "Мой заголовок")
    }

    func testDoneCategoryCompletesLocalTask() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: me)
        _ = await mirror(store, adapter: adapter).sync(full: true)
        adapter.issues["10001"]?.status = FakeJiraAdapter.done
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let taskFound = try await store.task(source: identity("10001"))
        let task = try XCTUnwrap(taskFound)
        XCTAssertEqual(task.status, .done)
        XCTAssertNotNil(task.completedAt)
        let versions = try await store.versions(taskID: task.id)
        XCTAssertEqual(versions.last?.actor, .provider)
    }

    func testDoneCategoryDoesNotTouchCancelled() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: me)
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let taskFound = try await store.task(source: identity("10001"))
        var task = try XCTUnwrap(taskFound)
        task.status = .cancelled
        _ = try await store.update(task, expectedRevision: task.revision, actor: .user)
        adapter.issues["10001"]?.status = FakeJiraAdapter.done
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let afterFound = try await store.task(source: identity("10001"))
        let after = try XCTUnwrap(afterFound)
        XCTAssertEqual(after.status, .cancelled)
    }

    func testLeftIssueWithActiveStatusIsKept() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: me)
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let taskFound = try await store.task(source: identity("10001"))
        var task = try XCTUnwrap(taskFound)
        task.status = .active
        _ = try await store.update(task, expectedRevision: task.revision, actor: .user)
        adapter.issues = [:]
        let result = await mirror(store, adapter: adapter).sync(full: true)
        XCTAssertEqual(result.left, 1)
        let afterFound = try await store.task(source: identity("10001"))
        let after = try XCTUnwrap(afterFound)
        XCTAssertEqual(after.source?.membership, .kept)
    }

    func testLeftIssueWithoutActivityIsNone() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: me)
        _ = await mirror(store, adapter: adapter).sync(full: true)
        adapter.issues = [:]
        _ = await mirror(store, adapter: adapter).sync(full: true)
        let afterFound = try await store.task(source: identity("10001"))
        let after = try XCTUnwrap(afterFound)
        XCTAssertEqual(after.source?.membership, TaskMembership.none)
        let observations = try await store.observations(taskID: after.id, limit: 10)
        XCTAssertEqual(observations.count, 1, "history stays")
    }

    func testRateLimitMidPageKeepsAppliedPagesAndDefers() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        let first = (0..<50).map { FakeJiraAdapter.issue(id: "2\($0)", key: "QA-\($0)", assignee: me) }
        let value = mirror(store, adapter: adapter)
        // Page one succeeds, the request for page two is rate-limited.
        adapter.searchPages = [(first, "tok-2"), ([], nil)]
        adapter.failNextSearchAfterPages = 1
        adapter.failNextSearch = .rateLimited(retryAfter: nil)
        let result = await value.sync(full: true)
        XCTAssertEqual(result.applied, 50)
        XCTAssertEqual(result.deferredUntil, now.addingTimeInterval(5))
        XCTAssertNotNil(result.failure)
        let tasks = try await store.tasks()
        XCTAssertEqual(tasks.count, 50)
        XCTAssertTrue(tasks.allSatisfy { $0.source?.membership == .assigned }, "a failed full sync never demotes anything")
        let deferred = await value.sync(full: true)
        XCTAssertEqual(deferred.applied, 0)
        XCTAssertEqual(deferred.deferredUntil, now.addingTimeInterval(5), "still deferred, no request made")
        XCTAssertEqual(adapter.jqls.count, 2)
    }

    func testMentionsQueryRejectedFallsBackToAssigned() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        adapter.issues["10001"] = FakeJiraAdapter.issue(id: "10001", key: "QA-1", assignee: me)
        adapter.rejectJQLContaining = "comment ~"
        let result = await mirror(store, adapter: adapter).sync(full: true)
        XCTAssertTrue(result.mentionsUnavailable)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(adapter.jqls.count, 2)
        XCTAssertFalse(adapter.jqls.last?.contains("comment ~") == true)
    }

    func testInvalidCursorRestartsPageOnce() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        let first = [FakeJiraAdapter.issue(id: "1", key: "QA-1", assignee: me)]
        let second = [FakeJiraAdapter.issue(id: "2", key: "QA-2", assignee: me)]
        adapter.searchPages = [(first, "tok-2"), (first, "tok-2"), (second, nil)]
        adapter.failNextSearchAfterPages = 1
        adapter.failNextSearch = .invalidCursor
        let result = await mirror(store, adapter: adapter).sync(full: true)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.applied, 3, "page one applied twice, page two once")
        let tasks = try await store.tasks()
        XCTAssertEqual(Set(tasks.compactMap { $0.source?.identity.externalID }), ["1", "2"])
    }

    func testIncrementalWindowUsesLastSync() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db), adapter = FakeJiraAdapter()
        let value = mirror(store, adapter: adapter)
        _ = await value.sync(full: true)
        XCTAssertFalse(adapter.jqls[0].contains("updated >="))
        now = now.addingTimeInterval(3600)
        _ = await value.sync(full: false)
        let incremental = try XCTUnwrap(adapter.jqls.last)
        XCTAssertTrue(incremental.contains("updated >= \""), incremental)
        XCTAssertTrue(incremental.contains("ORDER BY updated ASC"))
    }
}
