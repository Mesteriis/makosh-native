import Foundation
import MakoshCore
import XCTest
@testable import MakoshTasks

final class TasksQAIsolationTests: XCTestCase {
    private func configuration(
        _ schema: String, connection: String = "host=127.0.0.1 hostaddr=127.0.0.1 dbname=qa user=qa"
    ) -> PersonWorkspaceConfiguration {
        PersonWorkspaceConfiguration(connectionString: connection, schema: schema, archiveSchema: schema)
    }
    private let arguments = ["--tasks-synthetic-preview", "--database-config", "/tmp/qa.json"]

    func testValidateRequiresLoopbackAndPrefix() {
        XCTAssertNoThrow(try TasksQAIsolation.validate(configuration: configuration("qa_tasks_abc"), arguments: arguments))
        XCTAssertThrowsError(try TasksQAIsolation.validate(configuration: configuration("makosh"), arguments: arguments))
        XCTAssertThrowsError(try TasksQAIsolation.validate(configuration: configuration("qa_files_abc"), arguments: arguments))
        XCTAssertThrowsError(try TasksQAIsolation.validate(configuration: configuration("qa_tasks_"), arguments: arguments))
        XCTAssertThrowsError(
            try TasksQAIsolation.validate(
                configuration: configuration("qa_tasks_abc", connection: "host=db.example hostaddr=10.0.0.5 dbname=qa"),
                arguments: arguments))
        XCTAssertThrowsError(
            try TasksQAIsolation.validate(configuration: configuration("qa_tasks_abc"), arguments: ["--database-config", "/tmp/qa.json"]))
        XCTAssertThrowsError(
            try TasksQAIsolation.validate(
                configuration: configuration("qa_tasks_abc"), arguments: arguments + ["--files-synthetic-preview"]))
    }

    func testSeedCreatesBlockedAndOverdueTasks() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await TasksSyntheticSeed.seed(store: store, now: now)
        let tasks = try await store.tasks()
        XCTAssertEqual(tasks.count, 14)
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let blocked = tasks.filter { TaskDomain.isBlocked($0) { byID[$0] } }
        XCTAssertFalse(blocked.isEmpty, "at least one task waits for another")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        XCTAssertTrue(tasks.contains { TaskDomain.isOverdue($0, today: now, calendar: calendar) })
        XCTAssertTrue(tasks.contains { !$0.tags.isEmpty && $0.list != nil })
        try await TasksSyntheticSeed.seed(store: store, now: now)
        let again = try await store.tasks()
        XCTAssertEqual(again.count, 14, "seeding twice is a no-op")
        let connections = try await store.connections()
        XCTAssertEqual(connections.map(\.name), ["Синтетическая Jira"])
    }
}
