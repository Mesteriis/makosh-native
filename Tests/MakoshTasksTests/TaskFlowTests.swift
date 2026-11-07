import Foundation
import XCTest
@testable import MakoshTasks

final class TaskFlowTests: XCTestCase {
    func testProgressCountsDone() {
        let tasks = [Task(title: "a", status: .done), Task(title: "b"), Task(title: "c", status: .cancelled)]
        let progress = TaskFlowRules.progress(tasks)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.percent, 33)
        XCTAssertEqual(TaskFlowRules.progress([]).percent, 0)
    }

    func testReadyIsInboxWithoutOpenBlockers() {
        let blocker = Task(title: "блокер")
        let doneBlocker = Task(title: "сделан", status: .done)
        let waiting = Task(title: "ждёт", dependsOn: [blocker.id])
        let ready = Task(title: "готова", dependsOn: [doneBlocker.id])
        let active = Task(title: "в работе", status: .active)
        let all = [blocker, doneBlocker, waiting, ready, active]
        let resolve: (UUID) -> Task? = { id in all.first { $0.id == id } }
        XCTAssertFalse(TaskFlowRules.isReady(waiting, resolve: resolve))
        XCTAssertTrue(TaskFlowRules.isReady(ready, resolve: resolve))
        XCTAssertFalse(TaskFlowRules.isReady(active, resolve: resolve))
        XCTAssertEqual(TaskFlowRules.nextReady([waiting, active, ready], resolve: resolve)?.id, ready.id)
    }

    func testLayoutRanksByLongestPathAndHasNoOverlaps() {
        let a = Task(title: "A"), d = Task(title: "D")
        let b = Task(title: "B", dependsOn: [a.id])
        let c = Task(title: "C", dependsOn: [b.id, d.id])
        let layout = TaskFlowLayout.make([c, b, a, d])
        let x = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.x) })
        XCTAssertEqual(x[a.id], 0)
        XCTAssertEqual(x[d.id], 0)
        XCTAssertEqual(x[b.id], 280, "rank 1 = width 200 + gap 80")
        XCTAssertEqual(x[c.id], 560)
        XCTAssertEqual(layout.edges.count, 3)
        XCTAssertTrue(layout.edges.contains { $0.from == a.id && $0.to == b.id })
        for first in layout.nodes {
            for second in layout.nodes where first.id != second.id && first.x == second.x {
                XCTAssertGreaterThanOrEqual(abs(first.y - second.y), 76, "nodes of one rank never overlap")
            }
        }
        XCTAssertEqual(layout.size.width, 760)
        XCTAssertGreaterThanOrEqual(layout.size.height, 76 + 20 + 76)
        XCTAssertEqual(TaskFlowLayout.make([]).nodes, [])
    }

    func testLayoutOrdersRankByParentPosition() {
        let top = Task(title: "верх"), bottom = Task(title: "низ")
        let afterBottom = Task(title: "после низа", dependsOn: [bottom.id])
        let afterTop = Task(title: "после верха", dependsOn: [top.id])
        let layout = TaskFlowLayout.make([top, bottom, afterBottom, afterTop])
        let y = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.y) })
        XCTAssertLessThan(y[top.id]!, y[bottom.id]!, "rank 0 by title")
        XCTAssertLessThan(y[afterTop.id]!, y[afterBottom.id]!, "rank 1 follows the parents' order")
    }

    func testFlowsRoundTripInStore() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        let deadline = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.saveFlow(TaskFlow(name: "Релиз", description: "Выпуск 2.0", color: "#f472b6", deadline: deadline))
        try await store.saveFlow(TaskFlow(name: "Ремонт"))
        var flows = try await store.flows()
        XCTAssertEqual(flows.map(\.name), ["Релиз", "Ремонт"])
        XCTAssertEqual(flows.first?.description, "Выпуск 2.0")
        XCTAssertEqual(flows.first?.deadline, deadline)
        try await store.saveFlow(TaskFlow(name: "Релиз", description: "Выпуск 2.1"))
        flows = try await store.flows()
        XCTAssertEqual(flows.count, 2)
        XCTAssertEqual(flows.first?.description, "Выпуск 2.1")
        XCTAssertEqual(TaskFlow.palette.count, 10)
    }

    func testRemoveFlowClearsTasksButKeepsThem() async throws {
        let db = try tasksDatabase(), store = try await taskStore(db)
        try await store.saveFlow(TaskFlow(name: "Релиз"))
        let one = try await store.insert(Task(title: "a", flowID: "Релиз"), actor: .user)
        let other = try await store.insert(Task(title: "b", flowID: "Другая"), actor: .user)
        try await store.removeFlow(name: "Релиз")
        let flows = try await store.flows()
        XCTAssertTrue(flows.isEmpty)
        let cleared = try await store.task(id: one.id)
        XCTAssertNil(cleared?.flowID)
        XCTAssertNil(cleared?.deletedAt)
        XCTAssertEqual(cleared?.revision, 2)
        let untouched = try await store.task(id: other.id)
        XCTAssertEqual(untouched?.flowID, "Другая")
    }
}
