import Foundation
import MakoshCore
import MakoshJira
import XCTest
@testable import MakoshTasks

final class TaskStoreTests: XCTestCase {
    private func observation(_ identity: ServiceIdentity, summary: String, at: Date = Date()) -> TaskProviderObservation {
        let issue = JiraIssue(
            id: identity.externalID, key: "QA-1", projectKey: "QA", summary: summary,
            status: JiraStatus(id: "1", name: "To Do", category: .new), updated: at,
            browseURL: URL(string: "https://jira.test/browse/QA-1")!)
        return TaskProviderObservation(identity: identity, observedAt: at, raw: Data("{}".utf8), issue: issue)
    }

    func testInsertAssignsCodeAndFirstVersion() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let inserted = try await store.insert(Task(title: "Первая"), actor: .user)
        XCTAssertEqual(inserted.code.count, 5)
        XCTAssertEqual(inserted.revision, 1)
        let versions = try await store.versions(taskID: inserted.id)
        XCTAssertEqual(versions.map(\.revision), [1])
        XCTAssertEqual(versions.first?.actor, .user)
        let read = try await store.task(id: inserted.id)
        XCTAssertEqual(read, inserted)
        let byCode = try await store.task(code: inserted.code)
        XCTAssertEqual(byCode?.id, inserted.id)
    }

    func testUpdateWithStaleRevisionFails() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let inserted = try await store.insert(Task(title: "a"), actor: .user)
        var edit = inserted
        edit.title = "b"
        let updated = try await store.update(edit, expectedRevision: inserted.revision, actor: .user)
        XCTAssertEqual(updated.revision, 2)
        var stale = inserted
        stale.title = "c"
        do {
            _ = try await store.update(stale, expectedRevision: inserted.revision, actor: .user)
            XCTFail("stale revision must be refused")
        } catch let error as TaskStoreError { XCTAssertEqual(error, .staleRevision) }
        let read = try await store.task(id: inserted.id)
        XCTAssertEqual(read?.title, "b")
    }

    func testUpdateRecordsChangedFields() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let inserted = try await store.insert(Task(title: "a"), actor: .user)
        var edit = inserted
        edit.priority = 1
        edit.tags = ["x"]
        _ = try await store.update(edit, expectedRevision: 1, actor: .provider)
        let versions = try await store.versions(taskID: inserted.id)
        XCTAssertEqual(versions.last?.changedFields.sorted(), ["priority", "tags"])
        XCTAssertEqual(versions.last?.actor, .provider)
    }

    func testSoftDeleteHidesAndRestoreReturns() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let inserted = try await store.insert(Task(title: "a"), actor: .user)
        try await store.softDelete(id: inserted.id, expectedRevision: 1, actor: .user)
        let visible = try await store.tasks()
        XCTAssertTrue(visible.isEmpty)
        let all = try await store.tasks(includeDeleted: true)
        XCTAssertNotNil(all.first?.deletedAt)
        try await store.restore(id: inserted.id)
        let back = try await store.tasks()
        XCTAssertEqual(back.map(\.id), [inserted.id])
        XCTAssertNil(back.first?.deletedAt)
    }

    func testObservationVersionsAreAppendOnly() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let identity = ServiceIdentity(service: "jira", accountID: UUID().uuidString, externalID: "10001")
        let task = try await store.insert(
            Task(title: "QA-1", source: TaskSource(identity: identity, membership: .assigned)), actor: .provider)
        try await store.saveObservation(observation(identity, summary: "one", at: Date(timeIntervalSince1970: 1)), for: task.id)
        try await store.saveObservation(observation(identity, summary: "two", at: Date(timeIntervalSince1970: 2)), for: task.id)
        let versions = try await store.observations(taskID: task.id, limit: 10)
        XCTAssertEqual(versions.map(\.issue.summary), ["two", "one"])
        let latest = try await store.latestObservation(taskID: task.id)
        XCTAssertEqual(latest?.issue.summary, "two")
    }

    func testTaskBySourceIdentity() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let identity = ServiceIdentity(service: "jira", accountID: "c", externalID: "7")
        let task = try await store.insert(
            Task(title: "x", source: TaskSource(identity: identity, membership: .mentioned)), actor: .provider)
        let found = try await store.task(source: identity)
        XCTAssertEqual(found?.id, task.id)
        let missing = try await store.task(source: ServiceIdentity(service: "jira", accountID: "c", externalID: "8"))
        XCTAssertNil(missing)
    }

    func testPreferencesRoundTrip() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let initial = try await store.preferences()
        XCTAssertEqual(initial, TaskPreferences())
        var changed = initial
        changed.sort = .due
        changed.showCompleted = false
        changed.filter = "overdue"
        try await store.savePreferences(changed)
        let read = try await store.preferences()
        XCTAssertEqual(read, changed)
    }

    func testOpenIsIdempotent() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        try await store.open()
        let again = TaskStore(connectionString: db.connectionString, schema: db.schema)
        try await again.open()
        let tasks = try await again.tasks()
        XCTAssertTrue(tasks.isEmpty)
        _ = store
    }
}
