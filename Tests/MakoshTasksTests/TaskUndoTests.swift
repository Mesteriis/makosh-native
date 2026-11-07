import Foundation
import XCTest
@testable import MakoshTasks

final class TaskUndoTests: XCTestCase {
    private func step(_ title: String, at: Date) -> TaskUndoStep {
        let before = Task(title: title)
        var after = before
        after.title = title + "!"
        return TaskUndoStep(taskID: before.id, before: before, after: after, at: at)
    }

    func testKeepsAtMostFiveSteps() {
        var history = TaskUndoHistory()
        let now = Date()
        for index in 0..<7 { history.record(step("\(index)", at: now)) }
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.pop(now: now)?.before.title, "6")
        XCTAssertEqual(history.pop(now: now)?.before.title, "5")
    }

    func testExpiredStepIsDropped() {
        var history = TaskUndoHistory(lifetime: 60)
        let start = Date()
        history.record(step("old", at: start))
        history.record(step("fresh", at: start.addingTimeInterval(50)))
        XCTAssertEqual(history.pop(now: start.addingTimeInterval(100))?.before.title, "fresh")
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
        XCTAssertEqual(history.pop(now: now)?.before.title, "second")
        XCTAssertEqual(history.pop(now: now)?.before.title, "first")
        XCTAssertNil(history.pop(now: now))
    }
}
