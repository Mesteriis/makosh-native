import Foundation
import XCTest
@testable import MakoshTasks

final class TaskUndoTests: XCTestCase {
    private func step(_ title: String, at: Date) -> TaskUndoStep {
        let before = Task(title: title)
        var after = before
        after.title = title + "!"
        return TaskUndoStep(change: TaskChange(before: before, after: after), at: at)
    }

    func testKeepsAtMostFiveSteps() {
        var history = TaskUndoHistory()
        let now = Date()
        for index in 0..<7 { history.record(step("\(index)", at: now)) }
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.pop(now: now)?.changes.first?.before.title, "6")
        XCTAssertEqual(history.pop(now: now)?.changes.first?.before.title, "5")
    }

    func testExpiredStepIsDropped() {
        var history = TaskUndoHistory(lifetime: 60)
        let start = Date()
        history.record(step("old", at: start))
        history.record(step("fresh", at: start.addingTimeInterval(50)))
        XCTAssertEqual(history.pop(now: start.addingTimeInterval(100))?.changes.first?.before.title, "fresh")
        XCTAssertNil(history.pop(now: start.addingTimeInterval(100)), "the older step expired")
    }

    func testClearEmptiesHistory() {
        var history = TaskUndoHistory()
        history.record(step("a", at: Date()))
        history.clear()
        XCTAssertEqual(history.count, 0)
        XCTAssertNil(history.pop(now: Date()))
    }

    func testPopIsLIFO() {
        var history = TaskUndoHistory()
        let now = Date()
        history.record(step("first", at: now))
        history.record(step("second", at: now))
        XCTAssertEqual(history.pop(now: now)?.changes.first?.before.title, "second")
        XCTAssertEqual(history.pop(now: now)?.changes.first?.before.title, "first")
        XCTAssertNil(history.pop(now: now))
    }

    func testStepWithSeveralChangesPopsAsOne() {
        var history = TaskUndoHistory()
        let now = Date()
        let a = Task(title: "a"), b = Task(title: "b")
        var a2 = a, b2 = b
        a2.status = .done
        b2.status = .done
        let slot = TaskPlanSlot(planID: UUID(), taskID: a.id, start: 540, end: 600, kind: .task)
        history.record(
            TaskUndoStep(
                changes: [TaskChange(before: a, after: a2), TaskChange(before: b, after: b2)],
                slots: [TaskSlotChange(before: slot, after: nil)], at: now))
        XCTAssertEqual(history.count, 1)
        let popped = history.pop(now: now)
        XCTAssertEqual(popped?.changes.map(\.before.title), ["a", "b"])
        XCTAssertEqual(popped?.slots.first?.before, slot)
        XCTAssertNil(popped?.slots.first?.after)
        XCTAssertNil(history.pop(now: now))
    }
}
