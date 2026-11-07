import Foundation
import MakoshJira
import XCTest
@testable import MakoshTasks

final class TaskMeetingLinkTests: XCTestCase {
    func testKeysAreUniqueAndOrdered() {
        XCTAssertEqual(TaskMeetingLink.keys(in: "Созвон по OPS-7 и QA-12, снова OPS-7"), ["OPS-7", "QA-12"])
        XCTAssertEqual(TaskMeetingLink.keys(in: "Планёрка"), [])
        XCTAssertEqual(TaskMeetingLink.keys(in: "A_B2-3 у нас, abc-1 нет"), ["A_B2-3"])
    }

    func testKeyInsideWordIsIgnored() {
        XCTAssertEqual(TaskMeetingLink.keys(in: "XOPS-7"), ["XOPS-7"], "a longer key is still a key")
        XCTAssertEqual(TaskMeetingLink.keys(in: "1OPS-7"), [], "a digit before the project is not a boundary")
        XCTAssertEqual(TaskMeetingLink.keys(in: "OPS-70a"), ["OPS-70"], "letters after the number end the key")
        XCTAssertEqual(TaskMeetingLink.keys(in: "OPS-07"), [], "a leading zero is not an issue number")
        XCTAssertEqual(TaskMeetingLink.keys(in: "OPS-7000000000000"), [], "too many digits")
    }

    @MainActor func testHostFindsTaskByKey() async throws {
        let db = try tasksDatabase()
        let store = TaskStore(connectionString: db.connectionString, schema: db.schema)
        let service = TasksService(store: store, vault: JiraTokenVault(access: .memory()), adapterFactory: { _, _ in JiraSyntheticAdapter() })
        try await service.open()
        try await TasksSyntheticSeed.seed(store: store)
        let connections = try await store.connections()
        try await service.save(try XCTUnwrap(connections.first), token: "qa")
        let model = TasksWorkspaceModel(service: service)
        await model.refresh()
        await model.syncNow()
        let found = model.task(matchingKeysIn: "Созвон QA-1", notes: "")
        XCTAssertEqual(model.observation(id: found ?? UUID())?.issue.key, "QA-1")
        let byNotes = model.task(matchingKeysIn: "Созвон", notes: "см. OPS-8")
        XCTAssertEqual(model.observation(id: byNotes ?? UUID())?.issue.key, "OPS-8")
        await model.logMeeting(title: "Созвон QA-1", notes: "", meetingID: UUID(), seconds: 1800)
        XCTAssertEqual(model.draft?.taskID, found)
        XCTAssertEqual(model.draft?.source, .meeting)
        XCTAssertEqual(model.draft?.sendToJira, true)
    }

    @MainActor func testTwoKeysLeaveTaskUnset() async throws {
        let db = try tasksDatabase()
        let store = TaskStore(connectionString: db.connectionString, schema: db.schema)
        let service = TasksService(store: store, vault: JiraTokenVault(access: .memory()), adapterFactory: { _, _ in JiraSyntheticAdapter() })
        try await service.open()
        try await TasksSyntheticSeed.seed(store: store)
        let connections = try await store.connections()
        try await service.save(try XCTUnwrap(connections.first), token: "qa")
        let model = TasksWorkspaceModel(service: service)
        await model.refresh()
        await model.syncNow()
        XCTAssertNil(model.task(matchingKeysIn: "QA-1 и OPS-8", notes: ""))
        XCTAssertNil(model.task(matchingKeysIn: "ZZZ-9", notes: ""), "an unknown key finds nothing")
        await model.logMeeting(title: "QA-1 и OPS-8", notes: "", meetingID: UUID(), seconds: 600)
        XCTAssertNil(model.draft, "without one clear task the chooser decides, not a draft")
        XCTAssertNotNil(model.pendingMeetingTime)
        XCTAssertEqual(model.pendingMeetingTime?.seconds, 600)
    }
}
