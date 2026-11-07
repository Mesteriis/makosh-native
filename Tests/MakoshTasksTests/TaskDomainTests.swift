import Foundation
import XCTest
@testable import MakoshTasks

final class TaskDomainTests: XCTestCase {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }()
    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)!
    }
    private func task(_ title: String, status: TaskStatus = .inbox, dependsOn: [UUID] = [], due: Date? = nil) -> Task {
        Task(title: title, status: status, due: due, dependsOn: dependsOn)
    }
    private func resolver(_ tasks: [Task]) -> (UUID) -> Task? {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return { byID[$0] }
    }

    func testFullCycleWrapsAround() {
        XCTAssertEqual(TaskDomain.nextCycleStatus(.inbox, blocked: false), .active)
        XCTAssertEqual(TaskDomain.nextCycleStatus(.active, blocked: false), .done)
        XCTAssertEqual(TaskDomain.nextCycleStatus(.done, blocked: false), .cancelled)
        XCTAssertEqual(TaskDomain.nextCycleStatus(.cancelled, blocked: false), .inbox)
    }

    func testBlockedCycleSkipsActiveAndDone() {
        XCTAssertEqual(TaskDomain.nextCycleStatus(.inbox, blocked: true), .cancelled)
        XCTAssertEqual(TaskDomain.nextCycleStatus(.cancelled, blocked: true), .inbox)
        XCTAssertEqual(TaskDomain.nextCycleStatus(.active, blocked: true), .inbox, "a status outside the blocked cycle restarts it")
    }

    func testBlockedTaskCannotBecomeActive() {
        let blocker = task("blocker", status: .active)
        let blocked = task("blocked", dependsOn: [blocker.id])
        let resolve = resolver([blocker, blocked])
        XCTAssertTrue(TaskDomain.isBlocked(blocked, resolve: resolve))
        XCTAssertThrowsError(try TaskDomain.applying(status: .active, to: blocked, now: Date(), resolve: resolve)) { error in
            XCTAssertEqual(error as? TaskDomainError, .blocked(by: [blocker.id]))
        }
        XCTAssertNoThrow(try TaskDomain.applying(status: .cancelled, to: blocked, now: Date(), resolve: resolve))
    }

    func testCancelledBlockerDoesNotBlock() {
        let blocker = task("blocker", status: .cancelled)
        let blocked = task("blocked", dependsOn: [blocker.id])
        XCTAssertFalse(TaskDomain.isBlocked(blocked, resolve: resolver([blocker, blocked])))
    }

    func testMissingBlockerDoesNotBlock() {
        let blocked = task("blocked", dependsOn: [UUID()])
        XCTAssertFalse(TaskDomain.isBlocked(blocked, resolve: resolver([blocked])))
        XCTAssertEqual(TaskDomain.blockers(blocked, resolve: resolver([blocked])), [])
    }

    func testCycleDetectionThroughTwoHops() {
        let a = task("a")
        let b = task("b", dependsOn: [a.id])
        let c = task("c", dependsOn: [b.id])
        let resolve = resolver([a, b, c])
        XCTAssertTrue(TaskDomain.wouldCreateCycle(adding: c.id, to: a.id, resolve: resolve), "a → c → b → a")
        XCTAssertTrue(TaskDomain.wouldCreateCycle(adding: a.id, to: a.id, resolve: resolve), "self")
        XCTAssertFalse(TaskDomain.wouldCreateCycle(adding: a.id, to: c.id, resolve: resolve))
    }

    func testCompletionActivatesOnlyFullyUnblockedDependents() {
        let first = task("first", status: .done)
        let second = task("second", status: .active)
        let single = task("waits for first", dependsOn: [first.id])
        let double = task("waits for both", dependsOn: [first.id, second.id])
        let already = task("already active", status: .active, dependsOn: [first.id])
        let activated = TaskDomain.dependentsToActivate(after: first.id, among: [first, second, single, double, already])
        XCTAssertEqual(activated, [single.id])
    }

    func testOverdueIgnoresDoneAndCancelled() {
        let today = day("2026-11-07")
        let past = day("2026-11-01")
        XCTAssertTrue(TaskDomain.isOverdue(task("open", status: .active, due: past), today: today, calendar: calendar))
        XCTAssertFalse(TaskDomain.isOverdue(task("done", status: .done, due: past), today: today, calendar: calendar))
        XCTAssertFalse(TaskDomain.isOverdue(task("cancelled", status: .cancelled, due: past), today: today, calendar: calendar))
        XCTAssertFalse(TaskDomain.isOverdue(task("no due", status: .active), today: today, calendar: calendar))
    }

    func testOverdueIsStrictlyBeforeToday() {
        let today = day("2026-11-07")
        XCTAssertFalse(TaskDomain.isOverdue(task("today", status: .active, due: today), today: today, calendar: calendar))
        XCTAssertTrue(TaskDomain.isOverdue(task("yesterday", status: .active, due: day("2026-11-06")), today: today, calendar: calendar))
    }

    func testPostponeMovesPastDueToTomorrow() {
        let today = day("2026-11-07")
        let late = TaskDomain.postponed(task("late", due: day("2026-10-01")), today: today, calendar: calendar)
        XCTAssertEqual(late.due, day("2026-11-08"))
        XCTAssertEqual(late.postponed, 1)
        let ahead = TaskDomain.postponed(task("ahead", due: day("2026-11-20")), today: today, calendar: calendar)
        XCTAssertEqual(ahead.due, day("2026-11-21"))
        let none = TaskDomain.postponed(task("no due"), today: today, calendar: calendar)
        XCTAssertEqual(none.due, day("2026-11-08"))
    }

    func testDoneSetsCompletedAtAndRepeatIsNoop() throws {
        let now = day("2026-11-07")
        let open = task("open", status: .active)
        let done = try TaskDomain.applying(status: .done, to: open, now: now, resolve: resolver([open]))
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.completedAt, now)
        let again = try TaskDomain.applying(status: .done, to: done, now: day("2026-11-08"), resolve: resolver([done]))
        XCTAssertEqual(again, done, "a repeated done changes nothing")
    }

    func testLeavingDoneClearsCompletedAt() throws {
        let done = Task(title: "done", status: .done, completedAt: Date())
        let reopened = try TaskDomain.applying(status: .active, to: done, now: Date(), resolve: resolver([done]))
        XCTAssertNil(reopened.completedAt)
        XCTAssertEqual(reopened.status, .active)
    }
}
