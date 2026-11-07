import Foundation
import MakoshJira
import XCTest
@testable import MakoshTasks

/// The synthetic preview's data as the model sees it: both spaces filled.
@MainActor final class TasksSyntheticTests: XCTestCase {
    func testSeedFillsBothSpaces() async throws {
        let db = try tasksDatabase()
        let store = TaskStore(connectionString: db.connectionString, schema: db.schema)
        let jira = JiraSyntheticAdapter()
        let service = TasksService(store: store, vault: JiraTokenVault(access: .memory()), adapterFactory: { _, _ in jira })
        try await service.open()
        try await TasksSyntheticSeed.seed(store: store)
        let connections = try await store.connections()
        let connection = try XCTUnwrap(connections.first)
        try await service.save(connection, token: "qa-token")
        let model = TasksWorkspaceModel(service: service)
        await model.refresh()
        XCTAssertEqual(model.visible.count, 14, "local tasks before the first sync")
        await model.syncNow()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.visible.count, 20, "fourteen local tasks plus six mirrored issues")
        model.space = .jira(connection.id)
        XCTAssertEqual(model.visible.count, 6)
        XCTAssertEqual(model.board.map(\.title), ["To Do", "In Progress", "In Review", "Done"])
        XCTAssertEqual(model.board.map { $0.tasks.count }, [2, 2, 1, 1])
        let mentioned = model.visible.first { $0.source?.membership == .mentioned }
        XCTAssertEqual(model.observation(id: mentioned?.id ?? UUID())?.issue.key, "OPS-7")
    }

    func testSeedAddsFlowsPlanAndFocus() async throws {
        let db = try tasksDatabase()
        let store = TaskStore(connectionString: db.connectionString, schema: db.schema)
        try await store.open()
        try await TasksSyntheticSeed.seed(store: store)
        let flows = try await store.flows()
        XCTAssertEqual(flows.map(\.name), ["Релиз", "Ремонт"])
        XCTAssertEqual(flows.first?.color, "#f472b6")
        XCTAssertNotNil(flows.first?.deadline)
        let tasks = try await store.tasks()
        XCTAssertEqual(tasks.count, 14, "twelve tasks plus the two of «Ремонт»")
        XCTAssertEqual(tasks.filter { $0.flowID == "Релиз" }.count, 3)
        XCTAssertEqual(Set(tasks.flatMap(\.personas)), ["Боб", "Алиса"])
        XCTAssertEqual(tasks.first { $0.title == "Разобрать почту" }?.recurrence, "weekly")
        XCTAssertEqual(tasks.first { $0.title == "Перенести заметки" }?.notes.count, 2)
        let slots = try await store.slots(for: Date(), calendar: .current)
        XCTAssertEqual(slots.map(\.kind), [.task, .blocked])
        XCTAssertEqual(slots.last?.recurrence, .daily)
        XCTAssertEqual(slots.first?.taskID, TasksSyntheticSeed.id(2))
        let focus = try await store.focusState()
        XCTAssertEqual(focus?.waiting.map(\.taskID), [TasksSyntheticSeed.id(8)])
        XCTAssertEqual(focus?.waiting.first?.accumulatedSeconds, 420)
        XCTAssertNil(focus?.active)
        let preferences = try await store.preferences()
        XCTAssertFalse(preferences.focus.enabled)
        try await TasksSyntheticSeed.seed(store: store)
        let again = try await store.tasks()
        XCTAssertEqual(again.count, 14, "seeding twice changes nothing")
        let slotsAgain = try await store.slots(for: Date(), calendar: .current)
        XCTAssertEqual(slotsAgain.count, 2)
    }
}
