import Foundation
import MakoshCore
import MakoshJira
import XCTest
@testable import MakoshTasks

final class TaskFocusServiceTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value = Date(timeIntervalSince1970: 1_800_000_000)
        func now() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    private struct Harness {
        let store: TaskStore
        let time: TaskTimeService
        let focus: TaskFocusService
        let clock: Clock
        let a: Task
        let b: Task
    }

    private func harness() async throws -> Harness {
        let db = try tasksDatabase()
        let clock = Clock()
        let store = TaskStore(connectionString: db.connectionString, schema: db.schema, now: { clock.now() })
        try await store.open()
        let journal = TaskJiraAttemptJournal(store: store, now: { clock.now() }) { _ in nil }
        let time = TaskTimeService(store: store, journal: journal, now: { clock.now() })
        let focus = TaskFocusService(store: store, time: time, now: { clock.now() })
        let a = try await store.insert(Task(title: "A"), actor: .user)
        let b = try await store.insert(Task(title: "B"), actor: .user)
        return Harness(store: store, time: time, focus: focus, clock: clock, a: a, b: b)
    }

    func testFocusStartsTimerAndSwitchKeepsPreviousTime() async throws {
        let h = try await harness()
        _ = try await h.focus.focus(taskID: h.a.id)
        let first = try await h.store.timer()
        XCTAssertEqual(first?.taskID, h.a.id)
        h.clock.advance(300)
        let state = try await h.focus.focus(taskID: h.b.id)
        let second = try await h.store.timer()
        XCTAssertEqual(second?.taskID, h.b.id)
        XCTAssertEqual(second?.startedAt, h.clock.now())
        XCTAssertEqual(state.active?.taskID, h.b.id)
        XCTAssertEqual(state.waiting.map(\.taskID), [h.a.id])
        XCTAssertEqual(state.waiting.first?.accumulatedSeconds, 300)
        let entries = try await h.store.entries(taskID: h.a.id)
        XCTAssertTrue(entries.isEmpty, "switching writes no time entry")
        let stored = try await h.store.focusState()
        XCTAssertEqual(stored?.sessions.count, 2)
        XCTAssertNotNil(stored?.savedAt)
    }

    func testDoneYieldsDraftWithAccumulatedPlusRunning() async throws {
        let h = try await harness()
        _ = try await h.focus.focus(taskID: h.a.id)
        h.clock.advance(120)
        _ = try await h.focus.focus(taskID: h.b.id)
        h.clock.advance(60)
        _ = try await h.focus.focus(taskID: h.a.id)
        h.clock.advance(30)
        let draft = try await h.focus.done(taskID: h.a.id)
        XCTAssertEqual(draft?.taskID, h.a.id)
        XCTAssertEqual(draft?.source, .timer)
        XCTAssertEqual(draft?.seconds, 180, "120 s accumulated + 30 s running, rounded up to whole minutes")
        let timer = try await h.store.timer()
        XCTAssertNil(timer)
        let state = await h.focus.state()
        XCTAssertNil(state.active)
        XCTAssertEqual(state.waiting.map(\.taskID), [h.b.id])
        let entries = try await h.store.entries(taskID: h.a.id)
        XCTAssertTrue(entries.isEmpty, "the draft is not an entry yet")
    }

    func testWaitingUnderAMinuteIsRemovedWithoutDraft() async throws {
        let h = try await harness()
        _ = try await h.focus.focus(taskID: h.a.id)
        h.clock.advance(30)
        _ = try await h.focus.focus(taskID: h.b.id)
        let draft = try await h.focus.remove(taskID: h.a.id)
        XCTAssertNil(draft)
        let state = await h.focus.state()
        XCTAssertEqual(state.sessions.map(\.taskID), [h.b.id])
        let timer = try await h.store.timer()
        XCTAssertEqual(timer?.taskID, h.b.id, "the active session keeps its timer")
    }

    func testStopActiveYieldsDraftAndParkKeepsTime() async throws {
        let h = try await harness()
        _ = try await h.focus.focus(taskID: h.a.id)
        h.clock.advance(90)
        try await h.focus.park()
        let parked = await h.focus.state()
        XCTAssertNil(parked.active)
        XCTAssertEqual(parked.waiting.first?.accumulatedSeconds, 90)
        let timer = try await h.store.timer()
        XCTAssertNil(timer)
        _ = try await h.focus.focus(taskID: h.a.id)
        h.clock.advance(10)
        let draft = try await h.focus.stopActive()
        XCTAssertEqual(draft?.seconds, 120, "90 + 10 rounded up")
        let state = await h.focus.state()
        XCTAssertTrue(state.sessions.isEmpty)
    }

    func testPausePomodoroStopsTimerResumeRestarts() async throws {
        let h = try await harness()
        _ = try await h.focus.focus(taskID: h.a.id)
        try await h.focus.pomodoro(.start(minutes: 25))
        h.clock.advance(60)
        try await h.focus.pomodoro(.pause)
        let paused = try await h.store.timer()
        XCTAssertNil(paused, "the timer stops with the interval")
        let state = await h.focus.state()
        XCTAssertEqual(state.active?.accumulatedSeconds, 60)
        h.clock.advance(600)
        try await h.focus.pomodoro(.resume)
        let resumed = try await h.store.timer()
        XCTAssertEqual(resumed?.taskID, h.a.id)
        XCTAssertEqual(resumed?.startedAt, h.clock.now())
        try await h.focus.pomodoro(.stop)
        let stopped = try await h.store.timer()
        XCTAssertNotNil(stopped, "stopping the interval leaves attribution running")
        let idle = await h.focus.state()
        XCTAssertEqual(idle.pomodoro.phase, .idle)
    }

    func testPhaseTickMovesWorkToBreakAndBack() async throws {
        let h = try await harness()
        _ = try await h.focus.focus(taskID: h.a.id)
        try await h.focus.pomodoro(.start(minutes: 1))
        h.clock.advance(30)
        let early = try await h.focus.tickPhase(breakMinutes: 5)
        XCTAssertNil(early)
        h.clock.advance(30)
        let ended = try await h.focus.tickPhase(breakMinutes: 5)
        XCTAssertEqual(ended, .work)
        let onBreak = try await h.store.timer()
        XCTAssertNil(onBreak, "no attribution during the break")
        h.clock.advance(300)
        let breakEnded = try await h.focus.tickPhase(breakMinutes: 5)
        XCTAssertEqual(breakEnded, .break)
        let back = try await h.store.timer()
        XCTAssertEqual(back?.taskID, h.a.id)
        let state = await h.focus.state()
        XCTAssertEqual(state.todayCount(now: h.clock.now(), calendar: .current), 1)
    }

    func testTasksClosedReturnsDraftsForTheirSessions() async throws {
        let h = try await harness()
        _ = try await h.focus.focus(taskID: h.a.id)
        h.clock.advance(120)
        _ = try await h.focus.focus(taskID: h.b.id)
        h.clock.advance(60)
        let drafts = try await h.focus.tasksClosed([h.a.id, h.b.id])
        XCTAssertEqual(Set(drafts.map(\.taskID)), [h.a.id, h.b.id])
        XCTAssertEqual(drafts.first { $0.taskID == h.a.id }?.seconds, 120)
        XCTAssertEqual(drafts.first { $0.taskID == h.b.id }?.seconds, 60)
        let state = await h.focus.state()
        XCTAssertTrue(state.sessions.isEmpty)
        let timer = try await h.store.timer()
        XCTAssertNil(timer)
        let none = try await h.focus.tasksClosed([UUID()])
        XCTAssertTrue(none.isEmpty)
    }

    func testAdoptRunningTimerMakesItTheActiveSession() async throws {
        let h = try await harness()
        let timer = try await h.time.start(taskID: h.a.id, note: "")
        try await h.focus.adoptRunningTimer()
        let state = await h.focus.state()
        XCTAssertEqual(state.active?.taskID, h.a.id)
        XCTAssertEqual(state.active?.activeSince, timer.startedAt)
        try await h.focus.adoptRunningTimer()
        let again = await h.focus.state()
        XCTAssertEqual(again.sessions.count, 1, "adopting twice adds nothing")
    }

    func testRestoreOnLaunchParksActiveWithoutTimer() async throws {
        let h = try await harness()
        _ = try await h.focus.focus(taskID: h.a.id)
        try await h.store.clearTimer()
        try await h.focus.restoreOnLaunch()
        let state = await h.focus.state()
        XCTAssertNil(state.active, "an active session without its timer is parked")
        XCTAssertEqual(state.waiting.map(\.taskID), [h.a.id])
    }
}
