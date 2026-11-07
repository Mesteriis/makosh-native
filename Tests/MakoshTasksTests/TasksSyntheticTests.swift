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
        XCTAssertEqual(model.visible.count, 12, "local tasks before the first sync")
        await model.syncNow()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.visible.count, 18, "twelve local tasks plus six mirrored issues")
        model.space = .jira(connection.id)
        XCTAssertEqual(model.visible.count, 6)
        XCTAssertEqual(model.board.map(\.title), ["To Do", "In Progress", "In Review", "Done"])
        XCTAssertEqual(model.board.map { $0.tasks.count }, [2, 2, 1, 1])
        let mentioned = model.visible.first { $0.source?.membership == .mentioned }
        XCTAssertEqual(model.observation(id: mentioned?.id ?? UUID())?.issue.key, "OPS-7")
    }
}
