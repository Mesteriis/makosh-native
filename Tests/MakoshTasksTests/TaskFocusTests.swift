import Foundation
import XCTest
@testable import MakoshTasks

final class TaskFocusTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return value
    }

    func testFocusSwitchesActiveToWaitingAndAccumulates() {
        let a = UUID(), b = UUID()
        var state = TaskFocusState()
        state.focus(taskID: a, now: t0)
        XCTAssertEqual(state.active?.taskID, a)
        XCTAssertEqual(state.active?.activeSince, t0)
        state.focus(taskID: b, now: at(300))
        XCTAssertEqual(state.active?.taskID, b)
        XCTAssertEqual(state.waiting.map(\.taskID), [a])
        XCTAssertEqual(state.waiting.first?.accumulatedSeconds, 300)
        XCTAssertNil(state.waiting.first?.activeSince)
        XCTAssertEqual(state.waiting.first?.waitingSince, at(300))
        XCTAssertEqual(state.workSeconds(of: a, now: at(400)), 300)
        XCTAssertEqual(state.waitingSeconds(of: a, now: at(400)), 100)
        XCTAssertEqual(state.workSeconds(of: b, now: at(400)), 100)
        state.focus(taskID: a, now: at(400))
        XCTAssertEqual(state.active?.taskID, a)
        XCTAssertEqual(state.active?.accumulatedSeconds, 300)
        XCTAssertEqual(state.waiting.first?.accumulatedSeconds, 100)
        XCTAssertEqual(state.sessions.count, 2)
        state.park(now: at(500))
        XCTAssertNil(state.active)
        XCTAssertEqual(state.waiting.count, 2)
        XCTAssertEqual(state.workSeconds(of: a, now: at(900)), 400)
        state.remove(taskID: a, now: at(900))
        XCTAssertEqual(state.sessions.map(\.taskID), [b])
    }

    func testPauseFreezesCountdownAndAttribution() {
        let a = UUID()
        var state = TaskFocusState()
        state.focus(taskID: a, now: t0)
        state.startPomodoro(minutes: 25, now: t0)
        XCTAssertEqual(state.pomodoro.phase, .work)
        XCTAssertEqual(state.remaining(now: at(60)), 24 * 60)
        state.pause(now: at(60))
        XCTAssertEqual(state.remaining(now: at(120)), 24 * 60, "frozen while paused")
        XCTAssertEqual(state.workSeconds(of: a, now: at(120)), 60, "attribution pauses with it")
        XCTAssertNil(state.active?.activeSince)
        state.resume(now: at(120))
        XCTAssertEqual(state.remaining(now: at(180)), 23 * 60)
        XCTAssertEqual(state.workSeconds(of: a, now: at(180)), 120)
        state.stop(now: at(180))
        XCTAssertEqual(state.pomodoro.phase, .idle)
        XCTAssertEqual(state.remaining(now: at(200)), 0)
        XCTAssertEqual(state.workSeconds(of: a, now: at(240)), 180, "stopping the interval keeps attribution running")
        state.focus(taskID: UUID(), now: at(240))
        state.pause(now: at(240))
        XCTAssertEqual(state.pomodoro.phase, .idle, "pause without an interval is a no-op")
    }

    func testCompleteWorkPhaseCountsAndStartsBreak() {
        let a = UUID()
        var state = TaskFocusState()
        state.focus(taskID: a, now: t0)
        state.startPomodoro(minutes: 1, now: t0)
        XCTAssertNil(state.completePhase(now: at(30), breakMinutes: 5), "nothing ends before the time is up")
        XCTAssertEqual(state.completePhase(now: at(60), breakMinutes: 5), .work)
        XCTAssertEqual(state.pomodoro.phase, .break)
        XCTAssertEqual(state.pomodoro.plannedMinutes, 5)
        XCTAssertEqual(state.todayCount(now: at(60), calendar: calendar), 1)
        XCTAssertNil(state.active?.activeSince, "the task clock stops for the break")
        XCTAssertEqual(state.completePhase(now: at(360), breakMinutes: 5), .break)
        XCTAssertEqual(state.pomodoro.phase, .idle)
        XCTAssertEqual(state.active?.activeSince, at(360), "work resumes after the break")
        state.startPomodoro(minutes: 1, now: at(360))
        XCTAssertEqual(state.completePhase(now: at(420), breakMinutes: 0), .work)
        XCTAssertEqual(state.pomodoro.phase, .idle, "no break configured")
        XCTAssertEqual(state.todayCount(now: at(420), calendar: calendar), 2)
    }

    func testRestoreOnLaunchResetsExpiredPomodoroKeepsSessions() {
        let a = UUID()
        var state = TaskFocusState()
        state.focus(taskID: a, now: t0)
        state.startPomodoro(minutes: 10, now: t0)
        state.restoreOnLaunch(now: at(5 * 60))
        XCTAssertEqual(state.pomodoro.phase, .work, "a running interval survives a short restart")
        state.restoreOnLaunch(now: at(20 * 60))
        XCTAssertEqual(state.pomodoro.phase, .idle)
        XCTAssertEqual(
            state.todayCount(now: at(20 * 60), calendar: calendar), 0, "nothing is counted for an interval that ended unattended")
        XCTAssertEqual(state.sessions.map(\.taskID), [a])
        XCTAssertEqual(state.active?.taskID, a)
    }

    func testStateRoundTripsThroughJSON() throws {
        var state = TaskFocusState()
        state.focus(taskID: UUID(), now: t0)
        state.startPomodoro(minutes: 15, now: t0)
        state.savedAt = at(10)
        let data = try TaskStore.makeEncoder().encode(state)
        XCTAssertEqual(try TaskStore.makeDecoder().decode(TaskFocusState.self, from: data), state)
    }
}
